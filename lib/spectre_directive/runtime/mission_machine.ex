defmodule SpectreDirective.Runtime.MissionMachine do
  @moduledoc false

  @behaviour :gen_statem

  alias SpectreDirective.Loop.Engine
  alias SpectreDirective.Loop.State, as: LoopState
  alias SpectreDirective.MissionBlueprint
  alias SpectreDirective.Pulse
  alias SpectreDirective.Request
  alias SpectreDirective.Runtime.Notifier
  alias SpectreDirective.Runtime.RequestExecutor
  alias SpectreDirective.Runtime.State

  @task_supervisor SpectreDirective.TaskSupervisor

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: {__MODULE__, mission_id(opts)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  @doc false
  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) do
    :gen_statem.start_link(registry_name(mission_id(opts)), __MODULE__, opts, [])
  end

  @doc false
  @spec callback_mode() :: :gen_statem.callback_mode_result()
  @impl :gen_statem
  def callback_mode, do: :handle_event_function

  @doc false
  @spec init(keyword()) :: :gen_statem.init_result(atom())
  @impl :gen_statem
  def init(opts) do
    case initial_loop(opts) do
      {:ok, loop} ->
        state = State.new(loop, opts)
        {:ok, loop.status, state, [{:next_event, :internal, :drive}]}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @spec initial_loop(keyword()) :: {:ok, LoopState.t()} | {:error, term()}
  defp initial_loop(opts) do
    case Keyword.get(opts, :loop) do
      %LoopState{} = loop -> {:ok, loop}
      nil -> Engine.new(loop_attrs(Keyword.fetch!(opts, :blueprint), opts))
      other -> {:error, {:invalid_loop_state, other}}
    end
  end

  @doc false
  @spec handle_event(:gen_statem.event_type(), term(), atom(), State.t()) ::
          :gen_statem.handle_event_result()
  @impl :gen_statem
  def handle_event(:internal, :drive, _state_name, %State{} = state) do
    case Engine.next(state.loop) do
      {:request, request, loop} ->
        state =
          state
          |> Notifier.put_loop(loop)
          |> Notifier.request(request)
          |> maybe_start_worker(request)

        {:next_state, loop.status, state}

      {:done, outcome, loop} ->
        state = state |> Notifier.put_loop(loop) |> Notifier.outcome(outcome)
        {:next_state, loop.status, state}

      {:blocked, _reason, loop} ->
        {:next_state, loop.status, Notifier.put_loop(state, loop)}
    end
  end

  def handle_event({:call, from}, :pulse, _state_name, %State{} = state),
    do: keep_reply(from, {:ok, Pulse.from_loop(state.loop)}, state)

  def handle_event({:call, from}, :state, _state_name, %State{} = state),
    do: keep_reply(from, {:ok, state.loop}, state)

  def handle_event({:call, from}, :request, _state_name, %State{} = state),
    do: keep_reply(from, {:ok, state.loop.pending_request}, state)

  def handle_event({:call, from}, :outcome, _state_name, %State{} = state),
    do: keep_reply(from, {:ok, state.loop.outcome}, state)

  def handle_event({:call, from}, :trace, _state_name, %State{} = state),
    do: keep_reply(from, {:ok, state.loop.trace}, state)

  def handle_event({:call, from}, :plan, _state_name, %State{} = state),
    do: keep_reply(from, {:ok, state.loop.plan}, state)

  def handle_event({:call, from}, :context, _state_name, %State{} = state),
    do: keep_reply(from, {:ok, LoopState.context(state.loop, :inspect)}, state)

  def handle_event({:call, from}, {:subscribe, subscriber}, _state_name, %State{} = state)
      when is_pid(subscriber) do
    state = %{state | subscribers: MapSet.put(state.subscribers, subscriber)}
    Notifier.current_boundary(subscriber, state.loop)
    keep_reply(from, :ok, state)
  end

  def handle_event({:call, from}, {:inform, information, opts}, _state_name, %State{} = state) do
    pending_request = state.loop.pending_request

    case Engine.inform(state.loop, information, opts) do
      {:ok, loop} ->
        state =
          state
          |> maybe_clear_invalidated_worker(pending_request, loop)
          |> Notifier.put_loop(loop)

        Notifier.event(state, :information, List.last(loop.working_context.information))
        next_reply(from, {:ok, Pulse.from_loop(loop)}, state, maybe_drive(loop))

      {:error, reason} ->
        keep_reply(from, {:error, reason}, state)
    end
  end

  def handle_event({:call, from}, {:assign, assigns}, _state_name, %State{} = state) do
    pending_request = state.loop.pending_request

    case Engine.assign(state.loop, assigns) do
      {:ok, loop} ->
        state =
          state
          |> maybe_clear_invalidated_worker(pending_request, loop)
          |> Notifier.put_loop(loop)

        Notifier.event(state, :assigned, assigns)
        next_reply(from, {:ok, Pulse.from_loop(loop)}, state, maybe_drive(loop))

      {:error, reason} ->
        keep_reply(from, {:error, reason}, state)
    end
  end

  def handle_event({:call, from}, {:respond, request_id, response}, _state_name, %State{} = state) do
    respond_call(from, state, request_id, response)
  end

  def handle_event({:call, from}, {:respond, response}, _state_name, %State{} = state) do
    case state.loop.pending_request do
      %Request{id: request_id} -> respond_call(from, state, request_id, response)
      nil -> keep_reply(from, {:error, :no_pending_request}, state)
    end
  end

  def handle_event({:call, from}, {:control, action}, _state_name, %State{} = state) do
    control_call(from, state, action)
  end

  def handle_event({:call, from}, request, _state_name, %State{} = state),
    do: keep_reply(from, {:error, {:invalid_runtime_request, request}}, state)

  # A task result is accepted only while its monitor reference is still the
  # active one. Results from invalidated or timed-out work fall through to the
  # catch-all clause and cannot be applied to a newer request.
  def handle_event(
        :info,
        {ref, {:spectre_worker_result, response}},
        _state_name,
        %State{task: %Task{ref: ref}} = state
      ) do
    request = state.loop.pending_request
    request_id = state.task_request_id
    state = clear_worker(state, false)
    apply_worker_result(state, request, request_id, response)
  end

  def handle_event(
        :info,
        {ref, {:spectre_worker_error, reason}},
        _state_name,
        %State{task: %Task{ref: ref}} = state
      ) do
    request = state.loop.pending_request
    request_id = state.task_request_id
    state = clear_worker(state, false)
    apply_worker_failure(state, request, request_id, reason)
  end

  def handle_event(
        :info,
        {:DOWN, ref, :process, _pid, reason},
        _state_name,
        %State{task: %Task{ref: ref}} = state
      ) do
    request = state.loop.pending_request
    request_id = state.task_request_id
    state = clear_worker(state, false)
    apply_worker_failure(state, request, request_id, {:worker_crashed, reason})
  end

  def handle_event(
        :info,
        {:request_timeout, ref, request_id},
        _state_name,
        %State{task: %Task{ref: ref}, task_request_id: request_id} = state
      ) do
    request = state.loop.pending_request
    state = clear_worker(state, true)

    apply_worker_failure(
      state,
      request,
      request_id,
      {:request_timeout, state.request_timeout}
    )
  end

  def handle_event(:info, _message, _state_name, %State{} = state), do: {:keep_state, state}

  @doc false
  @spec terminate(term(), atom(), State.t()) :: :ok
  @impl :gen_statem
  def terminate(_reason, _state_name, %State{} = state) do
    clear_worker(state, true)
    :ok
  end

  @spec loop_attrs(MissionBlueprint.t(), keyword()) :: keyword()
  defp loop_attrs(%MissionBlueprint{} = blueprint, opts) do
    [
      mission: blueprint.mission,
      plan: blueprint.plan,
      plan_confirmed?: blueprint.plan.steps != [],
      mode: Keyword.get(opts, :mode, blueprint.mode),
      reasoner: Keyword.get(opts, :reasoner) || Keyword.get(opts, :model),
      reasoner_opts: Keyword.get(opts, :reasoner_opts, []),
      on_complete: Keyword.get(opts, :on_complete, blueprint.on_complete),
      input: Keyword.get(opts, :input),
      assigns: Keyword.get(opts, :assigns, %{}),
      information: Keyword.get(opts, :information, []),
      max_iterations: Keyword.get(opts, :max_iterations, 100),
      metadata: Map.merge(blueprint.metadata, Map.new(Keyword.get(opts, :metadata, %{})))
    ]
  end

  @spec respond_call(:gen_statem.from(), State.t(), binary(), term()) :: tuple()
  defp respond_call(from, %State{} = state, request_id, response) do
    case Engine.respond(state.loop, request_id, response) do
      {:error, reason, _loop} ->
        keep_reply(from, {:error, reason}, state)

      result ->
        loop = result_loop(result)
        state = state |> clear_worker(true) |> Notifier.put_loop(loop)
        next_reply(from, {:ok, Pulse.from_loop(loop)}, state, [{:next_event, :internal, :drive}])
    end
  end

  @spec control_call(:gen_statem.from(), State.t(), term()) :: tuple()
  defp control_call(from, %State{} = state, :pause) do
    case Engine.pause(state.loop) do
      {:ok, loop} ->
        state = state |> clear_worker(true) |> Notifier.put_loop(loop)
        next_reply(from, {:ok, Pulse.from_loop(loop)}, state, [])

      {:error, reason} ->
        keep_reply(from, {:error, reason}, state)
    end
  end

  defp control_call(from, %State{} = state, :resume) do
    case Engine.resume(state.loop) do
      {:ok, loop} ->
        state = Notifier.put_loop(state, loop)
        next_reply(from, {:ok, Pulse.from_loop(loop)}, state, [{:next_event, :internal, :drive}])

      {:error, reason} ->
        keep_reply(from, {:error, reason}, state)
    end
  end

  defp control_call(from, %State{} = state, :cancel),
    do: control_call(from, state, {:cancel, :cancelled})

  defp control_call(from, %State{} = state, {:cancel, reason}) do
    loop = Engine.cancel(state.loop, reason)

    state =
      state
      |> clear_worker(true)
      |> Notifier.put_loop(loop)
      |> Notifier.outcome(loop.outcome)

    next_reply(from, {:ok, Pulse.from_loop(loop)}, state, [])
  end

  defp control_call(from, %State{} = state, action),
    do: keep_reply(from, {:error, {:invalid_control, action}}, state)

  @spec apply_worker_response(State.t(), binary() | nil, term()) :: tuple()
  defp apply_worker_response(%State{} = state, request_id, response) do
    case Engine.respond(state.loop, request_id, response) do
      {:error, reason, loop} ->
        Notifier.event(state, :error, reason)
        {:next_state, loop.status, Notifier.put_loop(state, loop)}

      result ->
        loop = result_loop(result)
        state = Notifier.put_loop(state, loop)
        {:next_state, loop.status, state, [{:next_event, :internal, :drive}]}
    end
  end

  @spec apply_worker_result(State.t(), Request.t() | nil, binary() | nil, term()) :: tuple()
  defp apply_worker_result(
         %State{} = state,
         %Request{kind: :policy} = request,
         request_id,
         {:error, reason}
       ),
       do: apply_worker_failure(state, request, request_id, reason)

  defp apply_worker_result(%State{} = state, _request, request_id, response),
    do: apply_worker_response(state, request_id, response)

  @spec apply_worker_failure(State.t(), Request.t() | nil, binary() | nil, term()) :: tuple()
  defp apply_worker_failure(
         %State{} = state,
         %Request{kind: kind},
         _request_id,
         reason
       )
       when kind in [:question, :confirmation, :policy] do
    Notifier.event(state, :error, {:request_worker_failed, kind, reason})
    {:next_state, state.loop.status, state}
  end

  defp apply_worker_failure(%State{} = state, request, request_id, reason) do
    response = worker_failure_response(request, reason)
    apply_worker_response(state, request_id, response)
  end

  @spec maybe_start_worker(State.t(), Request.t()) :: State.t()
  defp maybe_start_worker(%State{task: %Task{}} = state, _request), do: state

  defp maybe_start_worker(%State{} = state, %Request{} = request) do
    case RequestExecutor.select(state, request) do
      nil ->
        state

      executor ->
        task =
          Task.Supervisor.async_nolink(@task_supervisor, fn ->
            RequestExecutor.execute(executor, request)
          end)

        timer_ref = start_timer(state.request_timeout, task.ref, request.id)

        %{state | task: task, task_request_id: request.id, timer_ref: timer_ref}
    end
  end

  @spec clear_worker(State.t(), boolean()) :: State.t()
  defp clear_worker(%State{task: nil} = state, _terminate?), do: state

  defp clear_worker(%State{task: %Task{} = task} = state, terminate?) do
    cancel_timer(state.timer_ref)
    Process.demonitor(task.ref, [:flush])

    if terminate? and Process.alive?(task.pid) do
      Task.Supervisor.terminate_child(@task_supervisor, task.pid)
    end

    %{state | task: nil, task_request_id: nil, timer_ref: nil}
  end

  @spec maybe_clear_invalidated_worker(State.t(), Request.t() | nil, LoopState.t()) :: State.t()
  defp maybe_clear_invalidated_worker(
         %State{} = state,
         %Request{kind: :reason},
         %LoopState{pending_request: nil}
       ),
       do: clear_worker(state, true)

  defp maybe_clear_invalidated_worker(%State{} = state, _old_request, %LoopState{}), do: state

  @spec start_timer(timeout(), reference(), binary()) :: reference() | nil
  defp start_timer(:infinity, _task_ref, _request_id), do: nil

  defp start_timer(timeout, task_ref, request_id),
    do: Process.send_after(self(), {:request_timeout, task_ref, request_id}, timeout)

  @spec cancel_timer(reference() | nil) :: :ok
  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer_ref) do
    Process.cancel_timer(timer_ref, async: false, info: false)
    :ok
  end

  @spec worker_failure_response(Request.t() | nil, term()) :: term()
  defp worker_failure_response(%Request{kind: :reason}, reason), do: {:blocked, reason}
  defp worker_failure_response(%Request{kind: :invoke}, reason), do: {:error, reason}
  defp worker_failure_response(_request, reason), do: {:error, reason}

  @spec result_loop(Engine.next_result()) :: LoopState.t()
  defp result_loop({:request, _request, loop}), do: loop
  defp result_loop({:done, _outcome, loop}), do: loop
  defp result_loop({:blocked, _reason, loop}), do: loop

  @spec maybe_drive(LoopState.t()) :: [tuple()]
  defp maybe_drive(%LoopState{pending_request: nil, status: status})
       when status not in [:paused, :blocked, :completed, :failed, :cancelled],
       do: [{:next_event, :internal, :drive}]

  defp maybe_drive(%LoopState{}), do: []

  @spec keep_reply(:gen_statem.from(), term(), State.t()) :: tuple()
  defp keep_reply(from, reply, state), do: {:keep_state, state, [{:reply, from, reply}]}

  @spec next_reply(:gen_statem.from(), term(), State.t(), [tuple()]) :: tuple()
  defp next_reply(from, reply, state, actions) do
    {:next_state, state.loop.status, state, [{:reply, from, reply} | actions]}
  end

  @spec mission_id(keyword()) :: binary()
  defp mission_id(opts) do
    case {Keyword.get(opts, :loop), Keyword.get(opts, :blueprint)} do
      {%LoopState{} = loop, _blueprint} -> loop.mission.id
      {nil, %MissionBlueprint{} = blueprint} -> blueprint.mission.id
      _other -> raise ArgumentError, "mission machine requires :loop or :blueprint"
    end
  end

  @spec registry_name(binary()) :: {:via, Registry, {module(), binary()}}
  defp registry_name(mission_id) do
    {:via, Registry, {SpectreDirective.Registry, mission_id}}
  end
end
