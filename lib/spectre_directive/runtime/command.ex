defmodule SpectreDirective.Command do
  @moduledoc """
  Small Port-based shell runner used by command job implementations.
  """

  @default_timeout_ms 60_000

  @type result :: %{
          command: binary(),
          cwd: binary() | nil,
          exit_status: non_neg_integer(),
          output: binary()
        }

  @doc """
  Runs a shell command through `bash -lc`, streaming output through `:emit`.
  """
  @spec run(binary(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(command, opts \\ []) when is_binary(command) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, {:runtime_unavailable, :bash}}
    else
      do_run(to_charlist(executable), command, opts)
    end
  end

  @spec do_run(charlist(), binary(), keyword()) :: {:ok, result()} | {:error, term()}
  defp do_run(executable, command, opts) do
    cwd = Keyword.get(opts, :cwd)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    emit = Keyword.get(opts, :emit, fn _type, _payload -> :ok end)

    port_opts =
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [~c"-lc", to_charlist(command)]
      ]
      |> maybe_put_cd(cwd)
      |> maybe_put_env(Keyword.get(opts, :env, %{}))

    emit.(:command_started, %{command: command, cwd: cwd, timeout_ms: timeout_ms})

    case SpectreDirective.Safe.call(fn ->
           Port.open({:spawn_executable, executable}, port_opts)
         end) do
      {:ok, port} ->
        started_at = System.monotonic_time(:millisecond)
        await_port(port, command, cwd, emit, timeout_ms, started_at, [])

      {:error, reason} ->
        {:error, {:command_start_failed, reason}}
    end
  end

  @spec await_port(
          port(),
          binary(),
          binary() | nil,
          (atom(), term() -> term()),
          pos_integer() | :infinity,
          integer(),
          iodata()
        ) :: {:ok, result()} | {:error, term()}
  defp await_port(port, command, cwd, emit, timeout_ms, started_at, output_parts) do
    remaining = remaining_timeout(timeout_ms, started_at)

    receive do
      {^port, {:data, chunk}} ->
        text = to_string(chunk)
        emit.(:stdout, text)
        await_port(port, command, cwd, emit, timeout_ms, started_at, [output_parts, text])

      {^port, {:exit_status, 0}} ->
        output = IO.iodata_to_binary(output_parts)
        result = %{command: command, cwd: cwd, exit_status: 0, output: output}
        emit.(:command_finished, result)
        {:ok, result}

      {^port, {:exit_status, status}} ->
        output = IO.iodata_to_binary(output_parts)
        result = %{command: command, cwd: cwd, exit_status: status, output: output}
        emit.(:command_failed, result)
        {:error, {:exit_status, status, result}}
    after
      remaining ->
        Port.close(port)
        output = IO.iodata_to_binary(output_parts)
        reason = {:timeout, timeout_ms, %{command: command, cwd: cwd, output: output}}
        emit.(:command_timeout, %{command: command, cwd: cwd, timeout_ms: timeout_ms})
        {:error, reason}
    end
  end

  @spec remaining_timeout(pos_integer() | :infinity | term(), integer()) ::
          non_neg_integer() | :infinity
  defp remaining_timeout(:infinity, _started_at), do: :infinity

  defp remaining_timeout(timeout_ms, started_at) when is_integer(timeout_ms) and timeout_ms > 0 do
    elapsed = System.monotonic_time(:millisecond) - started_at
    max(timeout_ms - elapsed, 0)
  end

  defp remaining_timeout(_timeout_ms, _started_at), do: @default_timeout_ms

  @spec maybe_put_cd([term()], binary() | nil) :: [term()]
  defp maybe_put_cd(opts, cwd) when is_binary(cwd) and cwd != "" do
    Keyword.put(opts, :cd, to_charlist(cwd))
  end

  defp maybe_put_cd(opts, _cwd), do: opts

  @spec maybe_put_env([term()], map() | term()) :: [term()]
  defp maybe_put_env(opts, env) when is_map(env) and map_size(env) > 0 do
    env =
      Enum.map(env, fn {key, value} ->
        {to_charlist(to_string(key)), to_charlist(to_string(value))}
      end)

    Keyword.put(opts, :env, env)
  end

  defp maybe_put_env(opts, _env), do: opts
end
