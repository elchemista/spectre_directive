defmodule SpectreDirective.MissionBlueprint do
  @moduledoc """
  Reusable definition of a mission loop.

  It contains only directive concerns: mission intent, an optional initial
  plan, execution mode, and an optional completion invocation. Runtime input,
  reasoners, policies, and application information are supplied when started.
  """

  alias SpectreDirective.ID
  alias SpectreDirective.Mission
  alias SpectreDirective.Plan
  alias SpectreDirective.Step

  @type mode :: :fixed | :guided | :autonomous
  @type source :: :authored | :agent_generated | :hybrid

  @type t :: %__MODULE__{
          id: binary(),
          name: binary(),
          mission: Mission.t(),
          mode: mode(),
          source: source(),
          plan: Plan.t(),
          on_complete: term(),
          metadata: map()
        }

  defstruct [
    :id,
    :name,
    :mission,
    :plan,
    :on_complete,
    mode: :guided,
    source: :authored,
    metadata: %{}
  ]

  @doc "Builds a reusable mission blueprint."
  @spec new(map() | keyword()) :: t()
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs)
    mission = Mission.new(Map.fetch!(attrs, :mission), status: :draft)
    source = Map.get(attrs, :source, :authored)
    plan = normalize_plan(Map.get(attrs, :plan), Map.get(attrs, :steps, []), source)

    %__MODULE__{
      id: Map.get(attrs, :id) || ID.new("blueprint"),
      name: to_string(Map.get(attrs, :name) || mission.goal || "mission"),
      mission: mission,
      mode: normalize_mode(Map.get(attrs, :mode, :guided)),
      source: source,
      plan: plan,
      on_complete: Map.get(attrs, :on_complete),
      metadata: Map.new(Map.get(attrs, :metadata, %{}))
    }
  end

  @doc "Builds a blueprint from a mission and optional authored steps."
  @spec from_mission(Mission.t() | binary() | map(), keyword()) :: t()
  def from_mission(mission, opts \\ []) do
    mission = Mission.new(mission, opts)
    source = Keyword.get(opts, :source, :agent_generated)

    new(
      name: Keyword.get(opts, :name, mission.goal),
      mission: mission,
      mode: Keyword.get(opts, :mode, :guided),
      source: source,
      plan: Keyword.get(opts, :plan),
      steps: Keyword.get(opts, :steps, []),
      on_complete: Keyword.get(opts, :on_complete),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  @doc "Creates an independent runtime copy with fresh mission, plan, and step identifiers."
  @spec instantiate(t(), keyword()) :: t()
  def instantiate(%__MODULE__{} = blueprint, opts \\ []) do
    mission_id = Keyword.get(opts, :id) || ID.new("mission")

    steps =
      Enum.map(blueprint.plan.steps, fn step ->
        Step.new(step,
          id: ID.new("step"),
          status: :pending,
          attempts: 0,
          evidence: [],
          result: nil
        )
      end)

    plan = %{
      blueprint.plan
      | id: ID.new("plan"),
        version: 1,
        steps: steps,
        skipped_steps: [],
        completed_steps: [],
        revision_history: [],
        current_step_id: nil
    }

    %{
      blueprint
      | id: ID.new("blueprint"),
        mission: %{blueprint.mission | id: mission_id, status: :draft},
        plan: plan
    }
  end

  @spec normalize_plan(term(), term(), source()) :: Plan.t()
  defp normalize_plan(%Plan{} = plan, _steps, _source), do: plan
  defp normalize_plan(nil, steps, source), do: Plan.new(List.wrap(steps), source: source)
  defp normalize_plan(plan, _steps, _source), do: Plan.new(plan)

  @spec normalize_mode(term()) :: mode()
  defp normalize_mode(:strict), do: :fixed
  defp normalize_mode(:adaptive), do: :autonomous
  defp normalize_mode(mode) when mode in [:fixed, :guided, :autonomous], do: mode
  defp normalize_mode(_mode), do: :guided
end
