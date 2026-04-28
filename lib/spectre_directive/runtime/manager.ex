defmodule SpectreDirective.Manager do
  @moduledoc """
  GenServer-owned task manager adapted from Symphony's orchestration pattern.
  """

  use GenServer
  require Logger

  alias SpectreDirective.{Event, Job, KineticAdapter, MemoryAdapter, Safe}
  alias SpectreDirective.Manager.State
  alias SpectreDirective.Task, as: DirectiveTask

  @terminal_statuses [:succeeded, :failed, :cancelled]
  @retry_base_ms 1_000

  @doc """
  Starts the task manager.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Resolves input and starts a tracked task.
  """
  @spec submit(term(), keyword()) :: {:ok, DirectiveTask.t()} | {:error, term()}
  def submit(input, opts \\ []) do
    Safe.result(fn -> GenServer.call(__MODULE__, {:submit, input, opts}) end)
  end

  @doc """
  Cancels a queued or running task.
  """
  @spec cancel(binary()) :: :ok | {:error, term()}
  def cancel(task_id), do: Safe.result(fn -> GenServer.call(__MODULE__, {:cancel, task_id}) end)

  @doc """
  Returns one task by id.
  """
  @spec status(binary()) :: {:ok, DirectiveTask.t()} | {:error, term()}
  def status(task_id), do: Safe.result(fn -> GenServer.call(__MODULE__, {:status, task_id}) end)

  @doc """
  Returns events for one task in chronological order.
  """
  @spec events(binary()) :: {:ok, [Event.t()]} | {:error, term()}
  def events(task_id), do: Safe.result(fn -> GenServer.call(__MODULE__, {:events, task_id}) end)

  @doc """
  Returns a snapshot of manager state.
  """
  @spec snapshot() :: map()
  def snapshot do
    case Safe.result(fn -> GenServer.call(__MODULE__, :snapshot) end) do
      {:ok, snapshot} -> snapshot
      {:error, reason} -> %{queued: [], running: [], completed: [], retrying: [], error: reason}
    end
  end

  @impl true
  @doc false
  @spec init(keyword()) :: {:ok, State.t()}
  def init(opts) do
    {:ok, %State{max_concurrent: Keyword.get(opts, :max_concurrent, System.schedulers_online())}}
  end

  @impl true
  @doc false
  @spec handle_call(term(), GenServer.from(), State.t()) :: {:reply, term(), State.t()}
  def handle_call({:submit, input, opts}, _from, state) do
    case Safe.result(fn -> KineticAdapter.resolve(input, opts) end) do
      {:ok, job} ->
        task = DirectiveTask.new(job, opts)
        state = put_task(state, %{task | status: :queued})
        {task, state} = dispatch_task(task, opts, state)
        {:reply, {:ok, task}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:cancel, task_id}, _from, state) do
    case get_task(state, task_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{status: status} when status in @terminal_statuses ->
        {:reply, :ok, state}

      task ->
        _ = Safe.result(fn -> Job.cancel(task.job, %{task_id: task_id}) end)

        if is_pid(task.pid) do
          Elixir.Task.Supervisor.terminate_child(SpectreDirective.TaskSupervisor, task.pid)
        end

        event = Event.new(task_id, :cancelled, %{reason: :requested})

        task =
          task
          |> append_event(event)
          |> Map.merge(%{status: :cancelled, finished_at: DateTime.utc_now()})

        {:reply, :ok, move_to_completed(state, task)}
    end
  end

  def handle_call({:status, task_id}, _from, state) do
    case get_task(state, task_id) do
      nil -> {:reply, {:error, :not_found}, state}
      task -> {:reply, {:ok, task}, state}
    end
  end

  def handle_call({:events, task_id}, _from, state) do
    case get_task(state, task_id) do
      nil -> {:reply, {:error, :not_found}, state}
      task -> {:reply, {:ok, Enum.reverse(task.events)}, state}
    end
  end

  def handle_call(:snapshot, _from, state) do
    {:reply,
     %{
       queued: Map.values(state.queued),
       running: Map.values(state.running),
       completed: Map.values(state.completed),
       retrying: retry_snapshot(state.retry_attempts),
       agent_totals: state.agent_totals,
       rate_limits: state.rate_limits
     }, state}
  end

  @impl true
  @doc false
  @spec handle_info(term(), State.t()) :: {:noreply, State.t()}
  def handle_info({:job_event, task_id, type, payload}, state) do
    event = Event.new(task_id, type, payload)
    record_event(event)

    state =
      update_existing_task(state, task_id, fn task ->
        task
        |> append_event(event)
        |> remember_activity(event)
        |> update_progress_from_event(type, payload)
      end)
      |> integrate_runtime_event(type, payload)

    {:noreply, state}
  end

  def handle_info({:job_result, task_id, {:ok, result}}, state) do
    task = get_task(state, task_id)
    event = Event.new(task_id, :succeeded, result)
    record_event(event)

    state =
      if task do
        task =
          task
          |> append_event(event)
          |> remember_activity(event)
          |> Map.merge(%{status: :succeeded, result: result, finished_at: DateTime.utc_now()})

        move_to_completed(state, task)
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:job_result, task_id, {:error, reason}}, state) do
    task = get_task(state, task_id)
    event = Event.new(task_id, :failed, reason)
    record_event(event)

    state =
      if task do
        task =
          task
          |> append_event(event)
          |> remember_activity(event)
          |> Map.merge(%{status: :failed, error: reason, finished_at: DateTime.utc_now()})

        move_to_completed(state, task)
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case find_running_by_ref(state.running, ref) do
      nil ->
        {:noreply, state}

      task ->
        event = Event.new(task.id, :failed, {:process_down, reason})
        record_event(event)

        task =
          task
          |> append_event(event)
          |> remember_activity(event)
          |> Map.merge(%{
            status: :failed,
            error: {:process_down, reason},
            finished_at: DateTime.utc_now()
          })

        {:noreply, move_to_completed(state, task)}
    end
  end

  def handle_info({:retry_task, task_id, retry_token}, state) do
    case Map.get(state.retry_attempts, task_id) do
      %{retry_token: ^retry_token, task: task, opts: opts, attempt: attempt} ->
        state = %{state | retry_attempts: Map.delete(state.retry_attempts, task_id)}
        {task, state} = dispatch_task(%{task | attempt: attempt}, opts, state)
        Logger.debug("Retried Directive task #{task.id}")
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  @spec dispatch_task(DirectiveTask.t(), keyword(), State.t()) :: {DirectiveTask.t(), State.t()}
  defp dispatch_task(task, opts, state) do
    if map_size(state.running) >= state.max_concurrent do
      {task, schedule_retry(state, task, opts, "no available task slots")}
    else
      start_task_child(task, opts, state)
    end
  end

  @spec start_task_child(DirectiveTask.t(), keyword(), State.t()) ::
          {DirectiveTask.t(), State.t()}
  defp start_task_child(task, opts, state) do
    parent = self()

    case safe_start_child(parent, task, opts) do
      {:ok, pid} ->
        task = mark_task_running(task, pid, opts)
        {task, put_running_task(state, task)}

      {:error, reason} ->
        {task, schedule_retry(state, task, opts, {:spawn_failed, reason})}
    end
  end

  @spec safe_start_child(pid(), DirectiveTask.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  defp safe_start_child(parent, task, opts) do
    Safe.result(fn ->
      Elixir.Task.Supervisor.start_child(SpectreDirective.TaskSupervisor, fn ->
        execute_job(parent, task, opts)
      end)
    end)
  end

  @spec mark_task_running(DirectiveTask.t(), pid(), keyword()) :: DirectiveTask.t()
  defp mark_task_running(task, pid, opts) do
    started = Event.new(task.id, :started, %{isolation: safe_isolation(task.job, Map.new(opts))})
    record_event(started)

    task
    |> append_event(started)
    |> remember_activity(started)
    |> Map.merge(%{
      status: :running,
      pid: pid,
      ref: Process.monitor(pid),
      started_at: DateTime.utc_now()
    })
  end

  @spec put_running_task(State.t(), DirectiveTask.t()) :: State.t()
  defp put_running_task(state, task) do
    %{
      state
      | queued: Map.delete(state.queued, task.id),
        running: Map.put(state.running, task.id, task),
        claimed: MapSet.put(state.claimed, task.id)
    }
  end

  @spec execute_job(pid(), DirectiveTask.t(), keyword()) :: {:job_result, binary(), term()}
  defp execute_job(parent, task, opts) do
    emit = fn type, payload -> send(parent, {:job_event, task.id, type, payload}) end

    context =
      opts
      |> Map.new()
      |> Map.merge(%{
        task_id: task.id,
        parent_id: task.parent_id,
        emit: emit
      })

    result = Safe.result(fn -> validate_and_run(task.job, context) end)
    send(parent, {:job_result, task.id, result})
  end

  @spec validate_and_run(term(), map()) :: {:ok, term()} | {:error, term()}
  defp validate_and_run(job, context) do
    with :ok <- Job.validate(job, context) do
      Job.run(job, context)
    end
  end

  @spec safe_isolation(term(), map()) :: map()
  defp safe_isolation(job, context) do
    case Safe.result(fn -> Job.isolation(job, context) end) do
      {:ok, isolation} when is_map(isolation) -> isolation
      {:ok, isolation} -> %{mode: :unknown, value: isolation}
      {:error, reason} -> %{mode: :unknown, error: reason}
    end
  end

  @spec record_event(Event.t()) :: :ok
  defp record_event(event) do
    _ = Safe.effect(fn -> MemoryAdapter.record(event) end)
    :ok
  end

  @spec schedule_retry(State.t(), DirectiveTask.t(), keyword(), term()) :: State.t()
  defp schedule_retry(state, task, opts, error) do
    attempt = task.attempt + 1
    delay_ms = retry_delay(attempt)
    retry_token = make_ref()
    timer_ref = Process.send_after(self(), {:retry_task, task.id, retry_token}, delay_ms)
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms

    retry = %{
      attempt: attempt,
      timer_ref: timer_ref,
      retry_token: retry_token,
      due_at_ms: due_at_ms,
      error: error,
      task: task,
      opts: opts
    }

    %{state | retry_attempts: Map.put(state.retry_attempts, task.id, retry)}
  end

  @spec retry_delay(pos_integer()) :: non_neg_integer()
  defp retry_delay(attempt) do
    max_delay = Application.get_env(:spectre_directive, :max_retry_backoff_ms, 30_000)
    min((@retry_base_ms * :math.pow(2, max(attempt - 1, 0))) |> round(), max_delay)
  end

  @spec put_task(State.t(), DirectiveTask.t()) :: State.t()
  defp put_task(state, task), do: %{state | queued: Map.put(state.queued, task.id, task)}

  @spec move_to_completed(State.t(), DirectiveTask.t()) :: State.t()
  defp move_to_completed(state, task) do
    if is_reference(task.ref), do: Process.demonitor(task.ref, [:flush])

    %{
      state
      | queued: Map.delete(state.queued, task.id),
        running: Map.delete(state.running, task.id),
        claimed: MapSet.delete(state.claimed, task.id),
        completed: Map.put(state.completed, task.id, %{task | pid: nil, ref: nil})
    }
  end

  @spec get_task(State.t(), binary()) :: DirectiveTask.t() | nil
  defp get_task(state, task_id) do
    Map.get(state.running, task_id) || Map.get(state.queued, task_id) ||
      Map.get(state.completed, task_id)
  end

  @spec update_existing_task(State.t(), binary(), (DirectiveTask.t() -> DirectiveTask.t())) ::
          State.t()
  defp update_existing_task(state, task_id, fun) do
    cond do
      Map.has_key?(state.running, task_id) ->
        %{state | running: Map.update!(state.running, task_id, fun)}

      Map.has_key?(state.queued, task_id) ->
        %{state | queued: Map.update!(state.queued, task_id, fun)}

      Map.has_key?(state.completed, task_id) ->
        %{state | completed: Map.update!(state.completed, task_id, fun)}

      true ->
        state
    end
  end

  @spec append_event(DirectiveTask.t(), Event.t()) :: DirectiveTask.t()
  defp append_event(task, event), do: %{task | events: [event | task.events]}

  @spec remember_activity(DirectiveTask.t(), Event.t()) :: DirectiveTask.t()
  defp remember_activity(task, %Event{} = event) do
    %{
      task
      | last_event: event.type,
        last_message: summarize_event_payload(event.payload),
        last_event_at: event.timestamp,
        session_id: extract_session_id(event.payload) || task.session_id
    }
  end

  @spec summarize_event_payload(term()) :: term()
  defp summarize_event_payload(payload) when is_map(payload) do
    cond do
      Map.has_key?(payload, :message) ->
        Map.get(payload, :message)

      Map.has_key?(payload, "message") ->
        Map.get(payload, "message")

      Map.has_key?(payload, :method) ->
        %{method: Map.get(payload, :method), session_id: extract_session_id(payload)}

      Map.has_key?(payload, "method") ->
        %{method: Map.get(payload, "method"), session_id: extract_session_id(payload)}

      Map.has_key?(payload, :payload) ->
        summarize_event_payload(Map.get(payload, :payload))

      Map.has_key?(payload, "payload") ->
        summarize_event_payload(Map.get(payload, "payload"))

      true ->
        payload
    end
  end

  defp summarize_event_payload(payload), do: payload

  @spec extract_session_id(term()) :: binary() | nil
  defp extract_session_id(payload) when is_map(payload) do
    Map.get(payload, :session_id) ||
      Map.get(payload, "session_id") ||
      Map.get(payload, "sessionId") ||
      payload
      |> Map.get(:payload)
      |> extract_session_id() ||
      payload
      |> Map.get("payload")
      |> extract_session_id()
  end

  defp extract_session_id(_payload), do: nil

  @spec update_progress_from_event(DirectiveTask.t(), atom(), term()) :: DirectiveTask.t()
  defp update_progress_from_event(task, :stdout, payload) do
    bytes = byte_size(to_string(payload))
    update_in(task.progress[:output_bytes], &((&1 || 0) + bytes))
  end

  defp update_progress_from_event(task, :command_finished, %{exit_status: status}) do
    put_in(task.progress[:exit_status], status)
  end

  defp update_progress_from_event(task, type, payload)
       when type in [:agent_usage, :token_usage] and is_map(payload) do
    usage = normalize_usage(payload)

    task
    |> put_in([Access.key(:progress), :input_tokens], usage.input_tokens)
    |> put_in([Access.key(:progress), :output_tokens], usage.output_tokens)
    |> put_in([Access.key(:progress), :total_tokens], usage.total_tokens)
  end

  defp update_progress_from_event(task, _type, _payload), do: task

  @spec integrate_runtime_event(State.t(), atom(), term()) :: State.t()
  defp integrate_runtime_event(state, type, payload)
       when type in [:agent_usage, :token_usage] and is_map(payload) do
    usage = normalize_usage(payload)

    update_in(state.agent_totals, fn totals ->
      %{
        input_tokens: Map.get(totals, :input_tokens, 0) + usage.input_tokens,
        output_tokens: Map.get(totals, :output_tokens, 0) + usage.output_tokens,
        total_tokens: Map.get(totals, :total_tokens, 0) + usage.total_tokens,
        seconds_running: Map.get(totals, :seconds_running, 0)
      }
    end)
  end

  defp integrate_runtime_event(state, :rate_limits, payload) when is_map(payload) do
    %{state | rate_limits: payload}
  end

  defp integrate_runtime_event(state, _type, _payload), do: state

  @spec normalize_usage(map()) :: %{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          total_tokens: non_neg_integer()
        }
  defp normalize_usage(payload) when is_map(payload) do
    input =
      integer_field(payload, [:input_tokens, "input_tokens", :prompt_tokens, "prompt_tokens"])

    output =
      integer_field(payload, [
        :output_tokens,
        "output_tokens",
        :completion_tokens,
        "completion_tokens"
      ])

    total = maybe_integer_field(payload, [:total_tokens, "total_tokens", :total])

    %{
      input_tokens: input,
      output_tokens: output,
      total_tokens: total || input + output
    }
  end

  @spec integer_field(map(), [atom() | binary()]) :: non_neg_integer()
  defp integer_field(payload, fields) do
    maybe_integer_field(payload, fields) || 0
  end

  @spec maybe_integer_field(map(), [atom() | binary()]) :: non_neg_integer() | nil
  defp maybe_integer_field(payload, fields) do
    Enum.find_value(fields, fn field -> parse_non_negative_integer(Map.get(payload, field)) end)
  end

  @spec parse_non_negative_integer(term()) :: non_neg_integer() | nil
  defp parse_non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp parse_non_negative_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> nil
    end
  end

  defp parse_non_negative_integer(_value), do: nil

  @spec find_running_by_ref(map(), reference()) :: DirectiveTask.t() | nil
  defp find_running_by_ref(running, ref) do
    Enum.find_value(running, fn {_id, task} ->
      if task.ref == ref, do: task
    end)
  end

  @spec retry_snapshot(map()) :: [map()]
  defp retry_snapshot(retry_attempts) do
    now_ms = System.monotonic_time(:millisecond)

    Enum.map(retry_attempts, fn {task_id, retry} ->
      %{
        task_id: task_id,
        attempt: retry.attempt,
        due_in_ms: max(0, retry.due_at_ms - now_ms),
        error: retry.error
      }
    end)
  end
end
