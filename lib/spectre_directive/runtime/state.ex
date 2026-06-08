defmodule SpectreDirective.Runtime.State do
  @moduledoc """
  Live runtime state for one mission process.
  """

  alias SpectreDirective.CapabilitySnapshot
  alias SpectreDirective.Knowledge
  alias SpectreDirective.MissionBlueprint
  alias SpectreDirective.Plan
  alias SpectreDirective.Planning.Session
  alias SpectreDirective.Pulse
  alias SpectreDirective.Step
  alias SpectreDirective.Trace.Entry

  @type t :: %__MODULE__{
          blueprint: MissionBlueprint.t(),
          knowledge: Knowledge.t(),
          capabilities: CapabilitySnapshot.t(),
          plan: Plan.t(),
          trace: [Entry.t()],
          pulse: Pulse.t() | nil,
          planning: Session.t() | nil,
          status: atom(),
          last_alignment: term(),
          approvals: MapSet.t(binary()),
          opts: keyword()
        }

  defstruct [
    :blueprint,
    :knowledge,
    :capabilities,
    :plan,
    :planning,
    :pulse,
    :last_alignment,
    status: :running,
    trace: [],
    approvals: MapSet.new(),
    opts: []
  ]

  @doc """
  Converts runtime state to a plain map for domain modules that consume snapshots.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = state), do: Map.from_struct(state)

  @doc """
  Updates the runtime and mission status together.
  """
  @spec put_status(t(), atom()) :: t()
  def put_status(%__MODULE__{} = state, status) when is_atom(status) do
    state
    |> Map.put(:status, status)
    |> put_in([Access.key(:blueprint), Access.key(:mission), Access.key(:status)], status)
  end

  @doc """
  Stores the most recent alignment result.
  """
  @spec put_alignment(t(), term()) :: t()
  def put_alignment(%__MODULE__{} = state, alignment) do
    %{state | last_alignment: alignment}
  end

  @doc """
  Rebuilds the live pulse from the current runtime state.
  """
  @spec refresh_pulse(t()) :: t()
  def refresh_pulse(%__MODULE__{} = state) do
    %{state | pulse: Pulse.from_state(to_map(state))}
  end

  @doc """
  Appends one trace entry to the mission story.
  """
  @spec add_trace(t(), atom(), binary(), term()) :: t()
  def add_trace(%__MODULE__{} = state, type, message, data \\ nil)
      when is_atom(type) and is_binary(message) do
    entry = Entry.new(state.blueprint.mission.id, type, message, data)
    %{state | trace: state.trace ++ [entry]}
  end

  @doc """
  Marks the supplied step as current and running.
  """
  @spec start_step(t(), Step.t()) :: t()
  def start_step(%__MODULE__{} = state, %Step{} = step) do
    %{state | plan: Plan.put_current(state.plan, step)}
  end

  @doc """
  Writes a changed step into the plan.
  """
  @spec put_step(t(), Step.t()) :: t()
  def put_step(%__MODULE__{} = state, %Step{} = step) do
    %{state | plan: Plan.update_step(state.plan, step)}
  end

  @doc """
  Replaces the current plan.
  """
  @spec put_plan(t(), Plan.t()) :: t()
  def put_plan(%__MODULE__{} = state, %Plan{} = plan) do
    %{state | plan: plan}
  end

  @doc """
  Clears the currently selected step.
  """
  @spec clear_current_step(t()) :: t()
  def clear_current_step(%__MODULE__{} = state) do
    %{state | plan: Plan.put_current(state.plan, nil)}
  end

  @doc """
  Records an approval for a step.
  """
  @spec approve_step(t(), binary()) :: t()
  def approve_step(%__MODULE__{} = state, step_id) when is_binary(step_id) do
    %{state | approvals: MapSet.put(state.approvals, step_id)}
  end

  @doc """
  Replaces the mission context.
  """
  @spec put_context(t(), binary()) :: t()
  def put_context(%__MODULE__{} = state, context) when is_binary(context) do
    put_in(state.blueprint.mission.context, context)
  end
end
