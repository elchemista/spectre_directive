defmodule SpectreDirective.Codex.AppServer do
  @moduledoc """
  Minimal Codex app-server JSON-RPC client.

  A custom client can be configured with:

      config :spectre_directive, :codex_client, MyClient

  The client must implement `run(job, context)`.
  """

  @initialize_id 1
  @thread_start_id 2
  @turn_start_id 3
  @port_line_bytes 1_048_576

  @doc """
  Runs one Codex agent job through a configured client or app-server process.
  """
  @spec run(SpectreDirective.Jobs.CodexAgent.t(), map()) :: {:ok, term()} | {:error, term()}
  def run(job, context) do
    client =
      Map.get(context, :codex_client) || Application.get_env(:spectre_directive, :codex_client)

    if client && Code.ensure_loaded?(client) && function_exported?(client, :run, 2) do
      SpectreDirective.Safe.result(fn -> client.run(job, context) end)
    else
      run_app_server(job, context)
    end
  end

  @spec run_app_server(SpectreDirective.Jobs.CodexAgent.t(), map()) ::
          {:ok, term()} | {:error, term()}
  defp run_app_server(job, context) do
    emit = Map.get(context, :emit, fn _type, _payload -> :ok end)

    with {:ok, cwd} <- validate_cwd(job.cwd),
         {:ok, port} <- start_port(job.command, cwd) do
      try do
        with :ok <- initialize(port),
             {:ok, thread_id} <- start_thread(port, job, cwd),
             {:ok, turn_id} <- start_turn(port, thread_id, job, cwd) do
          session_id = "#{thread_id}-#{turn_id}"

          emit.(:session_started, %{
            session_id: session_id,
            thread_id: thread_id,
            turn_id: turn_id
          })

          case await_turn_completion(port, job.timeout_ms, emit, session_id) do
            {:ok, result} -> {:ok, Map.put(result, :session_id, session_id)}
            {:error, reason} -> {:error, reason}
          end
        end
      after
        stop_port(port)
      end
    end
  end

  @spec validate_cwd(term()) :: {:ok, Path.t()} | {:error, term()}
  defp validate_cwd(cwd) when is_binary(cwd) and cwd != "" do
    expanded = Path.expand(cwd)

    if File.dir?(expanded) do
      {:ok, expanded}
    else
      {:error, {:invalid_cwd, expanded}}
    end
  end

  defp validate_cwd(_cwd), do: {:error, {:invalid_job, :missing_cwd}}

  @spec start_port(binary(), Path.t()) :: {:ok, port()} | {:error, term()}
  defp start_port(command, cwd) do
    executable = System.find_executable("bash")

    cond do
      is_nil(executable) ->
        {:error, {:runtime_unavailable, :bash}}

      String.trim(command || "") == "" ->
        {:error, {:invalid_job, :missing_codex_command}}

      true ->
        SpectreDirective.Safe.result(fn ->
          Port.open(
            {:spawn_executable, to_charlist(executable)},
            [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              args: [~c"-lc", to_charlist(command)],
              cd: to_charlist(cwd),
              line: @port_line_bytes
            ]
          )
        end)
    end
  end

  @spec stop_port(port()) :: :ok
  defp stop_port(port) when is_port(port) do
    Port.close(port)
    :ok
  rescue
    _ -> :ok
  end

  @spec initialize(port()) :: :ok | {:error, term()}
  defp initialize(port) do
    send_message(port, %{
      "method" => "initialize",
      "id" => @initialize_id,
      "params" => %{
        "capabilities" => %{"experimentalApi" => true},
        "clientInfo" => %{
          "name" => "spectre-directive",
          "title" => "SpectreDirective",
          "version" => "0.1.0"
        }
      }
    })

    with {:ok, _payload} <- await_response(port, @initialize_id) do
      send_message(port, %{"method" => "initialized", "params" => %{}})
      :ok
    end
  end

  @spec start_thread(port(), SpectreDirective.Jobs.CodexAgent.t(), Path.t()) ::
          {:ok, binary()} | {:error, term()}
  defp start_thread(port, job, cwd) do
    send_message(port, %{
      "method" => "thread/start",
      "id" => @thread_start_id,
      "params" => %{
        "approvalPolicy" => job.approval_policy,
        "sandbox" => job.thread_sandbox,
        "cwd" => cwd,
        "dynamicTools" => []
      }
    })

    case await_response(port, @thread_start_id) do
      {:ok, %{"thread" => %{"id" => thread_id}}} -> {:ok, thread_id}
      {:ok, payload} -> {:error, {:invalid_thread_payload, payload}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec start_turn(port(), binary(), SpectreDirective.Jobs.CodexAgent.t(), Path.t()) ::
          {:ok, binary()} | {:error, term()}
  defp start_turn(port, thread_id, job, cwd) do
    params =
      %{
        "threadId" => thread_id,
        "input" => [%{"type" => "text", "text" => job.prompt}],
        "cwd" => cwd,
        "title" => Map.get(job.metadata, :title) || "SpectreDirective Codex Task",
        "approvalPolicy" => job.approval_policy,
        "sandboxPolicy" => job.sandbox_policy
      }
      |> maybe_put_model(job.model)

    send_message(port, %{"method" => "turn/start", "id" => @turn_start_id, "params" => params})

    case await_response(port, @turn_start_id) do
      {:ok, %{"turn" => %{"id" => turn_id}}} -> {:ok, turn_id}
      {:ok, payload} -> {:error, {:invalid_turn_payload, payload}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec maybe_put_model(map(), binary() | nil) :: map()
  defp maybe_put_model(params, model) when is_binary(model) and model != "",
    do: Map.put(params, "model", model)

  defp maybe_put_model(params, _model), do: params

  @spec await_response(port(), integer(), binary()) :: {:ok, map()} | {:error, term()}
  defp await_response(port, id, pending_line \\ "") do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        line = pending_line <> to_string(chunk)

        case decode_line(line) do
          {:ok, %{"id" => ^id, "result" => result}} -> {:ok, result}
          {:ok, %{"id" => ^id, "error" => error}} -> {:error, {:rpc_error, error}}
          {:ok, _other} -> await_response(port, id, "")
          {:error, _reason} -> await_response(port, id, "")
        end

      {^port, {:data, {:noeol, chunk}}} ->
        await_response(port, id, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      30_000 -> {:error, :startup_timeout}
    end
  end

  @spec await_turn_completion(
          port(),
          pos_integer(),
          (atom(), term() -> term()),
          binary(),
          binary()
        ) :: {:ok, map()} | {:error, term()}
  defp await_turn_completion(port, timeout_ms, emit, session_id, pending_line \\ "") do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        line = pending_line <> to_string(chunk)
        handle_turn_line(port, timeout_ms, emit, session_id, line)

      {^port, {:data, {:noeol, chunk}}} ->
        await_turn_completion(
          port,
          timeout_ms,
          emit,
          session_id,
          pending_line <> to_string(chunk)
        )

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      normalize_timeout(timeout_ms) -> {:error, :turn_timeout}
    end
  end

  @spec handle_turn_line(port(), pos_integer(), (atom(), term() -> term()), binary(), binary()) ::
          {:ok, map()} | {:error, term()}
  defp handle_turn_line(port, timeout_ms, emit, session_id, line) do
    case decode_line(line) do
      {:ok, %{"method" => "turn/completed"} = payload} ->
        emit_usage(payload, emit)
        emit.(:turn_completed, %{session_id: session_id, payload: payload})
        {:ok, %{status: :completed, payload: payload}}

      {:ok, %{"method" => "turn/failed", "params" => params}} ->
        emit.(:turn_failed, %{session_id: session_id, params: params})
        {:error, {:turn_failed, params}}

      {:ok, %{"method" => "turn/cancelled", "params" => params}} ->
        emit.(:turn_cancelled, %{session_id: session_id, params: params})
        {:error, {:turn_cancelled, params}}

      {:ok, %{"method" => method} = payload} ->
        maybe_auto_approve(port, payload)
        emit_usage(payload, emit)
        emit_rate_limits(payload, emit)
        emit.(:notification, %{session_id: session_id, method: method, payload: payload})
        await_turn_completion(port, timeout_ms, emit, session_id)

      {:ok, payload} ->
        emit.(:notification, %{session_id: session_id, payload: payload})
        await_turn_completion(port, timeout_ms, emit, session_id)

      {:error, _reason} ->
        emit.(:codex_stream, line)
        await_turn_completion(port, timeout_ms, emit, session_id)
    end
  end

  @spec maybe_auto_approve(port(), map()) :: :ok
  defp maybe_auto_approve(port, %{"id" => id, "method" => method})
       when method in [
              "item/commandExecution/requestApproval",
              "execCommandApproval",
              "applyPatchApproval",
              "item/fileChange/requestApproval"
            ] do
    decision =
      case method do
        "item/commandExecution/requestApproval" -> "acceptForSession"
        "item/fileChange/requestApproval" -> "acceptForSession"
        _ -> "approved_for_session"
      end

    send_message(port, %{"id" => id, "result" => %{"decision" => decision}})
    :ok
  end

  defp maybe_auto_approve(_port, _payload), do: :ok

  @spec emit_usage(term(), (atom(), term() -> term())) :: :ok | term()
  defp emit_usage(payload, emit) do
    case find_usage(payload) do
      nil -> :ok
      usage -> emit.(:agent_usage, usage)
    end
  end

  @spec emit_rate_limits(term(), (atom(), term() -> term())) :: :ok | term()
  defp emit_rate_limits(payload, emit) do
    case find_rate_limits(payload) do
      nil -> :ok
      rate_limits -> emit.(:rate_limits, rate_limits)
    end
  end

  @spec find_usage(term()) :: map() | nil
  defp find_usage(payload) when is_map(payload) do
    direct =
      get_in(payload, ["params", "tokenUsage", "total"]) ||
        get_in(payload, ["params", "usage"]) ||
        Map.get(payload, "usage")

    cond do
      usage_map?(direct) -> direct
      usage_map?(payload) -> payload
      true -> payload |> Map.values() |> Enum.find_value(&find_usage/1)
    end
  end

  defp find_usage(payload) when is_list(payload), do: Enum.find_value(payload, &find_usage/1)
  defp find_usage(_payload), do: nil

  @spec usage_map?(term()) :: boolean()
  defp usage_map?(payload) when is_map(payload) do
    Enum.any?(
      [
        "input_tokens",
        "output_tokens",
        "total_tokens",
        "prompt_tokens",
        "completion_tokens",
        "inputTokens",
        "outputTokens",
        "totalTokens"
      ],
      &Map.has_key?(payload, &1)
    )
  end

  defp usage_map?(_payload), do: false

  @spec find_rate_limits(term()) :: map() | nil
  defp find_rate_limits(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits")

    cond do
      rate_limit_map?(direct) -> direct
      rate_limit_map?(payload) -> payload
      true -> payload |> Map.values() |> Enum.find_value(&find_rate_limits/1)
    end
  end

  defp find_rate_limits(payload) when is_list(payload),
    do: Enum.find_value(payload, &find_rate_limits/1)

  defp find_rate_limits(_payload), do: nil

  @spec rate_limit_map?(term()) :: boolean()
  defp rate_limit_map?(payload) when is_map(payload) do
    (Map.has_key?(payload, "limit_id") || Map.has_key?(payload, "limit_name")) &&
      Enum.any?(["primary", "secondary", "credits"], &Map.has_key?(payload, &1))
  end

  defp rate_limit_map?(_payload), do: false

  @spec send_message(port(), map()) :: true
  defp send_message(port, payload) do
    Port.command(port, Jason.encode!(payload))
    Port.command(port, "\n")
  end

  @spec decode_line(binary()) :: {:ok, term()} | {:error, Jason.DecodeError.t()}
  defp decode_line(line), do: Jason.decode(line)

  @spec normalize_timeout(term()) :: pos_integer()
  defp normalize_timeout(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0,
    do: timeout_ms

  defp normalize_timeout(_timeout_ms), do: 3_600_000
end
