defmodule SpectreDirective.Runtime.MissionMachine do
  @moduledoc """
  Finite-state runtime process for one live mission.

  This module is the OTP expression of the concept's directive loop. The state
  name is the mission status (`:running`, `:waiting`, `:paused`, `:finished`,
  and so on), while `SpectreDirective.Runtime.State` carries the living plan,
  knowledge, capabilities, trace, and pulse.

  The machine receives only a few public calls:

  * `:pulse`, `:trace`, `:plan`, and `:knowledge` inspect the mission.
  * `:next_step` selects a useful step if none is running.
  * `{:complete_step, observation}` records what happened and lets the plan
    correct itself.
  * `{:control, action}` applies user or supervisor control.

  The important architecture point is that the plan is not treated as fixed.
  Completing a step can change knowledge, derive impact, update alignment,
  revise the plan, and transition to a different mission status.
  """

  @behaviour :gen_statem

  alias SpectreDirective.MissionBlueprint
  alias SpectreDirective.Plan
  alias SpectreDirective.Planning.Proposal
  alias SpectreDirective.Planning.Session
  alias SpectreDirective.Planning.TextProvider
  alias SpectreDirective.Runtime.Bootstrap
  alias SpectreDirective.Runtime.Control
  alias SpectreDirective.Runtime.ObservationRecorder
  alias SpectreDirective.Runtime.State
  alias SpectreDirective.Runtime.StepGate

  @type state_name :: SpectreDirective.Mission.status()
  @type callback_reply ::
          {:keep_state, State.t(), [{:reply, :gen_statem.from(), term()}]}
          | {:next_state, state_name(), State.t(), [{:reply, :gen_statem.from(), term()}]}
          | {:keep_state, State.t()}

  @doc false
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) when is_list(opts) do
    blueprint = Keyword.fetch!(opts, :blueprint)
    :gen_statem.start_link(registry_name(blueprint), __MODULE__, opts, [])
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) when is_list(opts) do
    %{
      id: mission_child_id(opts),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @impl :gen_statem
  @spec callback_mode() :: :handle_event_function
  def callback_mode, do: :handle_event_function

  @impl :gen_statem
  @spec init(keyword()) :: {:ok, state_name(), State.t()}
  def init(opts) do
    state =
      opts
      |> Keyword.fetch!(:blueprint)
      |> Bootstrap.build(opts)
      |> State.add_trace(:started, started_message(opts))
      |> select_initial_step()
      |> State.refresh_pulse()

    {:ok, state.status, state}
  end

  @impl :gen_statem
  @spec handle_event(term(), term(), state_name(), State.t()) :: callback_reply()
  def handle_event({:call, from}, :pulse, _state_name, state),
    do: reply_keep_state(from, {:ok, state.pulse}, state)

  def handle_event({:call, from}, :trace, _state_name, state),
    do: reply_keep_state(from, {:ok, state.trace}, state)

  def handle_event({:call, from}, :plan, _state_name, state),
    do: reply_keep_state(from, {:ok, state.plan}, state)

  def handle_event({:call, from}, :knowledge, _state_name, state),
    do: reply_keep_state(from, {:ok, state.knowledge}, state)

  def handle_event({:call, from}, :capabilities, _state_name, state),
    do: reply_keep_state(from, {:ok, state.capabilities}, state)

  def handle_event({:call, from}, :planning_state, _state_name, state) do
    reply_keep_state(from, planning_state_reply(state), state)
  end

  def handle_event({:call, from}, {:propose_plan_item, opts}, _state_name, state) do
    case planning_session(state) do
      {:ok, %Session{pending: %Proposal{} = pending}} ->
        reply_keep_state(from, {:error, {:pending_plan_item, pending.id}}, state)

      {:ok, session} ->
        with {:ok, provider} <- planning_provider(state, opts),
             {:ok, session, proposal} <-
               Session.propose(
                 session,
                 provider,
                 state.blueprint,
                 state.knowledge,
                 state.capabilities,
                 Keyword.merge(state.opts, opts)
               ) do
          state =
            state
            |> put_planning(session)
            |> State.add_trace(:planning_proposal, proposal_message(proposal), proposal)
            |> notify_planning(:planning_proposal, proposal)
            |> notify_planning(:planning_updated, Session.public(session))
            |> State.refresh_pulse()

          reply_next_state(from, {:ok, proposal}, state)
        else
          {:error, reason} -> reply_keep_state(from, {:error, reason}, state)
        end

      {:error, reason} ->
        reply_keep_state(from, {:error, reason}, state)
    end
  end

  def handle_event({:call, from}, {:submit_plan_item, item}, _state_name, state) do
    with {:ok, session} <- planning_session(state),
         {:ok, session, proposal} <- Session.submit(session, item) do
      state =
        state
        |> put_planning(session)
        |> State.add_trace(:planning_proposal, "Received external planning proposal.", proposal)
        |> notify_planning(:planning_proposal, proposal)
        |> notify_planning(:planning_updated, Session.public(session))
        |> State.refresh_pulse()

      reply_next_state(from, {:ok, proposal}, state)
    else
      {:error, reason} -> reply_keep_state(from, {:error, reason}, state)
    end
  end

  def handle_event({:call, from}, {:accept_plan_item, item_or_edit}, _state_name, state) do
    with {:ok, session} <- planning_session(state),
         {:ok, session, proposal} <- Session.accept(session, item_or_edit) do
      state =
        state
        |> put_planning(session)
        |> State.add_trace(:planning_accepted, accepted_message(proposal), proposal)
        |> notify_planning(:planning_updated, Session.public(session))
        |> State.refresh_pulse()

      reply_next_state(from, {:ok, Session.public(session)}, state)
    else
      {:error, reason} -> reply_keep_state(from, {:error, reason}, state)
    end
  end

  def handle_event({:call, from}, {:reject_plan_item, reason}, _state_name, state) do
    with {:ok, session} <- planning_session(state),
         {:ok, session} <- Session.reject(session, reason) do
      state =
        state
        |> put_planning(session)
        |> State.add_trace(:planning_rejected, "Rejected planning proposal.", reason)
        |> notify_planning(:planning_updated, Session.public(session))
        |> State.refresh_pulse()

      reply_next_state(from, {:ok, Session.public(session)}, state)
    else
      {:error, reason} -> reply_keep_state(from, {:error, reason}, state)
    end
  end

  def handle_event({:call, from}, {:finish_planning, reason}, _state_name, state) do
    case planning_session(state) do
      {:ok, session} ->
        state = finish_manual_planning(state, session, reason)
        reply_next_state(from, {:ok, state.pulse}, state)

      {:error, reason} ->
        reply_keep_state(from, {:error, reason}, state)
    end
  end

  def handle_event({:call, from}, :next_step, _state_name, state) do
    if state.status == :planning do
      reply_keep_state(from, {:error, :planning_in_progress}, state)
    else
      state =
        state
        |> select_step_if_needed()
        |> State.refresh_pulse()

      reply_next_state(from, {:ok, Plan.current_step(state.plan)}, state)
    end
  end

  def handle_event(
        {:call, from},
        {:complete_step, _observation_payload},
        _state_name,
        %State{status: :planning} = state
      ) do
    reply_keep_state(from, {:error, :planning_in_progress}, state)
  end

  def handle_event({:call, from}, {:complete_step, observation_payload}, _state_name, state) do
    state =
      state
      # ObservationRecorder performs the post-step half of the concept loop:
      # observation -> impact -> knowledge update -> correction.
      |> ObservationRecorder.complete_current(observation_payload)
      |> StepGate.select_next()
      |> State.refresh_pulse()

    reply_next_state(from, {:ok, state.pulse}, state)
  end

  def handle_event({:call, from}, {:control, action}, _state_name, state) do
    state =
      state
      # Controls are explicit human/supervisor interventions. They share the
      # same state pipeline as autonomous corrections so pulse and trace stay
      # consistent.
      |> Control.apply_action(action)
      |> State.refresh_pulse()

    reply_next_state(from, {:ok, state.pulse}, state)
  end

  def handle_event({:call, from}, message, _state_name, state) do
    state =
      State.add_trace(state, :control_ignored, "Unknown runtime call ignored.", message)

    reply_keep_state(from, {:error, {:unknown_call, message}}, state)
  end

  def handle_event(_event_type, _event, _state_name, state), do: {:keep_state, state}

  @spec reply_keep_state(:gen_statem.from(), term(), State.t()) :: callback_reply()
  defp reply_keep_state(from, reply, state), do: {:keep_state, state, [{:reply, from, reply}]}

  @spec reply_next_state(:gen_statem.from(), term(), State.t()) :: callback_reply()
  defp reply_next_state(from, reply, state),
    do: {:next_state, state.status, state, [{:reply, from, reply}]}

  @spec select_step_if_needed(State.t()) :: State.t()
  defp select_step_if_needed(%State{} = state) do
    state.plan
    |> Plan.current_step()
    |> select_step_if_needed(state)
  end

  @spec select_step_if_needed(SpectreDirective.Step.t() | nil, State.t()) :: State.t()
  defp select_step_if_needed(nil, state), do: StepGate.select_next(state)
  defp select_step_if_needed(_step, state), do: state

  @spec select_initial_step(State.t()) :: State.t()
  defp select_initial_step(%State{status: :planning} = state), do: state

  defp select_initial_step(%State{} = state) do
    # The first useful step is selected immediately so a pulse can explain
    # what the mission expects next as soon as the process starts.
    StepGate.select_next(state)
  end

  @spec planning_state_reply(State.t()) :: {:ok, map()} | {:error, :not_planning}
  defp planning_state_reply(%State{planning: %Session{} = session}),
    do: {:ok, Session.public(session)}

  defp planning_state_reply(%State{}), do: {:error, :not_planning}

  @spec planning_session(State.t()) :: {:ok, Session.t()} | {:error, :not_planning}
  defp planning_session(%State{status: :planning, planning: %Session{} = session}),
    do: {:ok, session}

  defp planning_session(%State{}), do: {:error, :not_planning}

  @spec finish_manual_planning(State.t(), Session.t(), term()) :: State.t()
  defp finish_manual_planning(%State{} = state, %Session{} = session, reason) do
    {plan, session, finish_reason} = Session.finish_plan(session, reason)

    state
    |> put_planning(session)
    |> State.put_plan(plan)
    |> State.put_status(:running)
    |> State.add_trace(:planned, "Finished manual guided planning.", %{
      mode: :guided,
      reason: finish_reason,
      steps: Enum.map(plan.steps, & &1.title)
    })
    |> notify_planning(:planning_updated, Session.public(session))
    |> StepGate.select_next()
    |> State.refresh_pulse()
  end

  @spec planning_provider(State.t(), keyword()) ::
          {:ok, TextProvider.provider()} | {:error, term()}
  defp planning_provider(%State{} = state, opts) do
    state.opts
    |> Keyword.merge(opts)
    |> TextProvider.from_opts()
    |> case do
      nil -> {:error, :planning_provider_required}
      :none -> {:error, :planning_provider_required}
      provider -> {:ok, provider}
    end
  end

  @spec put_planning(State.t(), Session.t()) :: State.t()
  defp put_planning(%State{} = state, %Session{} = session), do: %{state | planning: session}

  @spec notify_planning(State.t(), atom(), term()) :: State.t()
  defp notify_planning(%State{} = state, event, payload) when is_atom(event) do
    state.opts
    |> Keyword.get(:planning_subscribers, [])
    |> List.wrap()
    |> Enum.each(fn pid ->
      if is_pid(pid) do
        send(pid, {:spectre_directive, state.blueprint.mission.id, event, payload})
      end
    end)

    state
  end

  @spec proposal_message(Proposal.t()) :: binary()
  defp proposal_message(%Proposal{type: type}), do: "Received #{type} planning proposal."

  @spec accepted_message(Proposal.t()) :: binary()
  defp accepted_message(%Proposal{type: type}), do: "Accepted #{type} planning proposal."

  @spec registry_name(MissionBlueprint.t()) :: {:via, Registry, {module(), binary()}}
  defp registry_name(%MissionBlueprint{} = blueprint) do
    {:via, Registry, {SpectreDirective.Registry, blueprint.mission.id}}
  end

  @spec mission_child_id(keyword()) :: {module(), binary()}
  defp mission_child_id(opts) do
    blueprint = Keyword.fetch!(opts, :blueprint)
    {__MODULE__, blueprint.mission.id}
  end

  @spec started_message(keyword()) :: binary()
  defp started_message(opts) do
    blueprint = Keyword.fetch!(opts, :blueprint)
    "Started mission: #{blueprint.mission.goal}"
  end
end
