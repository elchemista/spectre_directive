defmodule SpectreDirective.Runtime.MissionProcesses do
  @moduledoc false

  alias SpectreDirective.MissionBlueprint
  alias SpectreDirective.Outcome
  alias SpectreDirective.Runtime.MissionMachine

  @registry SpectreDirective.Registry
  @mission_supervisor SpectreDirective.MissionSupervisor

  @doc false
  @spec start(MissionBlueprint.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(%MissionBlueprint{} = blueprint, opts) do
    with :ok <- SpectreDirective.Runtime.Supervisor.ensure_started(runtime_opts(opts)) do
      child = {MissionMachine, Keyword.put(opts, :blueprint, blueprint)}
      DynamicSupervisor.start_child(@mission_supervisor, child)
    end
  end

  @doc false
  @spec start_loop(SpectreDirective.Loop.State.t(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def start_loop(%SpectreDirective.Loop.State{} = loop, opts) do
    with :ok <- SpectreDirective.Runtime.Supervisor.ensure_started(runtime_opts(opts)) do
      child = {MissionMachine, Keyword.put(opts, :loop, loop)}
      DynamicSupervisor.start_child(@mission_supervisor, child)
    end
  end

  @doc false
  @spec pulse(pid() | binary()) :: {:ok, SpectreDirective.Pulse.t()} | {:error, term()}
  def pulse(ref), do: call(ref, :pulse)

  @doc false
  @spec state(pid() | binary()) :: {:ok, SpectreDirective.Loop.State.t()} | {:error, term()}
  def state(ref), do: call(ref, :state)

  @doc false
  @spec request(pid() | binary()) :: {:ok, SpectreDirective.Request.t() | nil} | {:error, term()}
  def request(ref), do: call(ref, :request)

  @doc false
  @spec outcome(pid() | binary()) :: {:ok, SpectreDirective.Outcome.t() | nil} | {:error, term()}
  def outcome(ref), do: call(ref, :outcome)

  @doc false
  @spec trace(pid() | binary()) :: {:ok, [SpectreDirective.Trace.Entry.t()]} | {:error, term()}
  def trace(ref), do: call(ref, :trace)

  @doc false
  @spec plan(pid() | binary()) :: {:ok, SpectreDirective.Plan.t()} | {:error, term()}
  def plan(ref), do: call(ref, :plan)

  @doc false
  @spec context(pid() | binary()) :: {:ok, SpectreDirective.Context.t()} | {:error, term()}
  def context(ref), do: call(ref, :context)

  @doc false
  @spec subscribe(pid() | binary(), pid()) :: :ok | {:error, term()}
  def subscribe(ref, subscriber \\ self()), do: call(ref, {:subscribe, subscriber})

  @doc false
  @spec respond(pid() | binary(), binary(), term()) ::
          {:ok, SpectreDirective.Pulse.t()} | {:error, term()}
  def respond(ref, request_id, response), do: call(ref, {:respond, request_id, response})

  @doc false
  @spec respond(pid() | binary(), term()) :: {:ok, SpectreDirective.Pulse.t()} | {:error, term()}
  def respond(ref, response), do: call(ref, {:respond, response})

  @doc false
  @spec inform(pid() | binary(), term(), keyword()) ::
          {:ok, SpectreDirective.Pulse.t()} | {:error, term()}
  def inform(ref, information, opts \\ []), do: call(ref, {:inform, information, opts})

  @doc false
  @spec assign(pid() | binary(), map()) ::
          {:ok, SpectreDirective.Pulse.t()} | {:error, term()}
  def assign(ref, assigns), do: call(ref, {:assign, assigns})

  @doc false
  @spec control(pid() | binary(), term()) :: {:ok, SpectreDirective.Pulse.t()} | {:error, term()}
  def control(ref, action), do: call(ref, {:control, action})

  @doc false
  @spec stop(pid() | binary()) :: :ok | {:error, term()}
  def stop(ref) when is_pid(ref), do: stop_pid(ref)

  def stop(ref) when is_binary(ref) do
    case lookup(ref) do
      {:ok, pid} -> stop_pid(pid)
      {:error, reason} -> {:error, reason}
    end
  end

  def stop(_ref), do: {:error, :not_found}

  @doc false
  @spec await(pid() | binary(), timeout()) :: {:ok, Outcome.t()} | {:error, term()}
  def await(ref, timeout \\ 60_000)
  def await(ref, :infinity), do: do_await(ref, :infinity)

  def await(ref, timeout) when is_integer(timeout) and timeout >= 0 do
    do_await(ref, System.monotonic_time(:millisecond) + timeout)
  end

  def await(_ref, timeout), do: {:error, {:invalid_timeout, timeout}}

  @spec call(pid() | binary(), term()) :: term()
  defp call(ref, message) when is_pid(ref), do: safe_call(ref, message)

  defp call(ref, message) when is_binary(ref) do
    case lookup(ref) do
      {:ok, pid} -> safe_call(pid, message)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec call(term(), term()) :: {:error, :not_found}
  defp call(_ref, _message), do: {:error, :not_found}

  @spec safe_call(pid(), term()) :: term()
  defp safe_call(pid, message) do
    :gen_statem.call(pid, message)
  catch
    :exit, {:noproc, _details} -> {:error, :not_found}
    :exit, {:normal, _details} -> {:error, :not_found}
    :exit, reason -> {:error, {:runtime_exit, reason}}
  end

  @spec do_await(pid() | binary(), integer() | :infinity) ::
          {:ok, Outcome.t()} | {:error, term()}
  defp do_await(ref, deadline) do
    case outcome(ref) do
      {:ok, %Outcome{} = outcome} ->
        {:ok, outcome}

      {:ok, nil} ->
        await_next_poll(ref, deadline)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec await_next_poll(pid() | binary(), integer() | :infinity) ::
          {:ok, Outcome.t()} | {:error, term()}
  defp await_next_poll(ref, deadline) do
    if timed_out?(deadline) do
      {:error, :timeout}
    else
      Process.sleep(20)
      do_await(ref, deadline)
    end
  end

  @spec timed_out?(integer() | :infinity) :: boolean()
  defp timed_out?(:infinity), do: false
  defp timed_out?(deadline), do: System.monotonic_time(:millisecond) >= deadline

  @spec stop_pid(pid()) :: :ok | {:error, term()}
  defp stop_pid(pid) do
    if Process.whereis(@mission_supervisor) do
      DynamicSupervisor.terminate_child(@mission_supervisor, pid)
    else
      {:error, :not_found}
    end
  end

  @spec lookup(binary()) :: {:ok, pid()} | {:error, :not_found}
  defp lookup(mission_id) do
    if Process.whereis(@registry) do
      case Registry.lookup(@registry, mission_id) do
        [{pid, _value}] -> {:ok, pid}
        [] -> {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end

  @spec runtime_opts(keyword()) :: keyword()
  defp runtime_opts(opts), do: Keyword.get(opts, :runtime_opts, [])
end
