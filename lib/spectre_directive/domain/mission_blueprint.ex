defmodule SpectreDirective.MissionBlueprint do
  @moduledoc """
  Reusable mission definition shared by authored, emergent, and hybrid missions.

  A mission blueprint is the normalized internal form produced by both:

  * authored modules using `use SpectreDirective`, and
  * emergent missions started with `SpectreDirective.start_mission/2`.

  The blueprint is not the live runtime state. It is the reusable definition:
  mission, mode, memory hints, capability rules, strategy names, alignment
  rules, correction rules, and an initial plan.

      blueprint =
        SpectreDirective.MissionBlueprint.from_mission(
          "Analyze a GitHub profile for React frontend fit",
          context: "React evidence matters more than backend evidence.",
          success: "A concise fit summary with evidence."
        )

  Once a mission starts, the runtime copies the blueprint and assigns fresh
  mission and blueprint ids. That keeps authored definitions reusable across
  many mission runs.
  """

  alias SpectreDirective.ID
  alias SpectreDirective.Mission
  alias SpectreDirective.Plan
  alias SpectreDirective.Step

  @type mode :: :strict | :guided | :adaptive
  @type source :: :authored | :agent_generated | :hybrid

  @type t :: %__MODULE__{
          id: binary(),
          name: binary(),
          mission: Mission.t(),
          mode: mode(),
          source: source(),
          memory: map(),
          capability_rules: map(),
          strategies: [atom()],
          alignment_rules: [term()],
          correction_rules: [term()],
          plan: Plan.t(),
          metadata: map()
        }

  defstruct [
    :id,
    :name,
    :mission,
    :plan,
    mode: :guided,
    source: :authored,
    memory: %{},
    capability_rules: %{required: [], allowed: [], denied: []},
    strategies: [],
    alignment_rules: [],
    correction_rules: [],
    metadata: %{}
  ]

  @doc """
  Builds a mission blueprint from normalized attributes.
  """
  @spec new(map() | keyword()) :: t()
  def new(attrs) do
    attrs = Map.new(attrs)
    mission = Mission.new(Map.fetch!(attrs, :mission), status: :draft)
    steps = Map.get(attrs, :steps, [])
    plan = Map.get(attrs, :plan) || Plan.new(steps, source: Map.get(attrs, :source, :authored))

    %__MODULE__{
      id: Map.get(attrs, :id) || ID.new("blueprint"),
      name: to_string(Map.get(attrs, :name) || mission.goal || "mission_blueprint"),
      mission: mission,
      mode: Map.get(attrs, :mode, :guided),
      source: Map.get(attrs, :source, :authored),
      memory: Map.new(Map.get(attrs, :memory, %{})),
      capability_rules:
        Map.get(attrs, :capability_rules, %{required: [], allowed: [], denied: []}),
      strategies: List.wrap(Map.get(attrs, :strategies, [])),
      alignment_rules: List.wrap(Map.get(attrs, :alignment_rules, [])),
      correction_rules: List.wrap(Map.get(attrs, :correction_rules, [])),
      plan: plan,
      metadata: Map.new(Map.get(attrs, :metadata, %{}))
    }
  end

  @doc """
  Builds an emergent mission blueprint from a mission.
  """
  @spec from_mission(Mission.t() | binary() | map(), keyword()) :: t()
  def from_mission(mission, opts \\ []) do
    mission = Mission.new(mission, opts)
    source = Keyword.get(opts, :source, :agent_generated)

    new(
      name: Keyword.get(opts, :name, mission.goal),
      mission: mission,
      mode: Keyword.get(opts, :mode, :adaptive),
      source: source,
      memory: %{scope: mission.memory_scope},
      strategies: Keyword.get(opts, :strategies, [:focused_research]),
      steps: Keyword.get(opts, :steps, default_steps(source))
    )
  end

  @spec default_steps(source()) :: [Step.t()]
  defp default_steps(source) do
    [
      Step.new("Recall known information",
        kind: :remember,
        purpose: "Use existing memory before planning new work.",
        source: source,
        flexibility: :locked
      ),
      Step.new("Observe current state",
        kind: :observe,
        purpose: "Inspect the current situation before acting.",
        source: source,
        flexibility: :guided
      ),
      Step.new("Investigate mission-relevant evidence",
        kind: :investigate,
        purpose: "Gather information that directly helps the mission.",
        source: source,
        flexibility: :agentic
      ),
      Step.new("Verify mission result",
        kind: :verify,
        purpose: "Check whether the mission can be answered.",
        source: source,
        flexibility: :locked
      ),
      Step.new("Summarize outcome",
        kind: :summarize,
        purpose: "Produce the final mission answer with evidence and uncertainty.",
        source: source,
        flexibility: :locked
      )
    ]
  end
end
