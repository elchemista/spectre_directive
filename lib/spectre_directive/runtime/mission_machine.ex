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
      # The first useful step is selected immediately so a pulse can explain
      # what the mission expects next as soon as the process starts.
      |> StepGate.select_next()
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

  def handle_event({:call, from}, :next_step, _state_name, state) do
    state =
      state
      |> select_step_if_needed()
      |> State.refresh_pulse()

    reply_next_state(from, {:ok, Plan.current_step(state.plan)}, state)
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
