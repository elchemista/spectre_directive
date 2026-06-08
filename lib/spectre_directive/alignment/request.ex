defmodule SpectreDirective.Alignment.Request do
  @moduledoc """
  Structured request passed to an application alignment module.
  """

  alias SpectreDirective.CapabilitySnapshot
  alias SpectreDirective.Knowledge
  alias SpectreDirective.Mission
  alias SpectreDirective.MissionBlueprint
  alias SpectreDirective.Plan
  alias SpectreDirective.Strategies
  alias SpectreDirective.Step

  @type t :: %__MODULE__{
          mission: Mission.t() | nil,
          blueprint: MissionBlueprint.t() | nil,
          knowledge: Knowledge.t(),
          capabilities: CapabilitySnapshot.t(),
          plan: Plan.t() | nil,
          step: Step.t() | nil,
          status: atom() | nil,
          phase: :pre_step | :post_step,
          strategies: [atom()],
          alignment_rules: [term()],
          correction_rules: [term()],
          capability_rules: map(),
          current_step: Step.t() | nil,
          next_step: Step.t() | nil,
          completed_steps: [Step.t()],
          skipped_steps: [Step.t()],
          prompt: binary() | nil,
          state: map(),
          opts: keyword()
        }

  defstruct [
    :mission,
    :blueprint,
    :knowledge,
    :capabilities,
    :plan,
    :step,
    :status,
    :phase,
    :current_step,
    :next_step,
    :prompt,
    :state,
    opts: [],
    strategies: [],
    alignment_rules: [],
    correction_rules: [],
    capability_rules: %{},
    completed_steps: [],
    skipped_steps: []
  ]

  @doc """
  Builds an alignment request from runtime state.
  """
  @spec new(map(), Step.t() | nil, :pre_step | :post_step) :: t()
  def new(state, step, phase) when is_map(state) do
    blueprint = Map.get(state, :blueprint)
    plan = Map.get(state, :plan)

    request = %__MODULE__{
      mission: mission(blueprint),
      blueprint: blueprint,
      knowledge: knowledge(state),
      capabilities: capabilities(state),
      plan: plan,
      step: step,
      status: Map.get(state, :status),
      phase: phase,
      strategies: strategies(blueprint),
      alignment_rules: alignment_rules(blueprint),
      correction_rules: correction_rules(blueprint),
      capability_rules: capability_rules(blueprint),
      current_step: current_step(plan),
      next_step: step,
      completed_steps: completed_steps(plan),
      skipped_steps: skipped_steps(plan),
      state: state,
      opts: Map.get(state, :opts, [])
    }

    %{request | prompt: prompt(request)}
  end

  @spec mission(MissionBlueprint.t() | nil) :: Mission.t() | nil
  defp mission(nil), do: nil
  defp mission(%MissionBlueprint{} = blueprint), do: blueprint.mission

  @spec knowledge(map()) :: Knowledge.t()
  defp knowledge(state) do
    case Map.get(state, :knowledge) do
      %Knowledge{} = knowledge -> knowledge
      _other -> Knowledge.new(nil)
    end
  end

  @spec capabilities(map()) :: CapabilitySnapshot.t()
  defp capabilities(state) do
    case Map.get(state, :capabilities) do
      %CapabilitySnapshot{} = capabilities -> capabilities
      _other -> CapabilitySnapshot.new([])
    end
  end

  @spec alignment_rules(MissionBlueprint.t() | nil) :: [term()]
  defp alignment_rules(nil), do: []
  defp alignment_rules(%MissionBlueprint{} = blueprint), do: blueprint.alignment_rules

  @spec correction_rules(MissionBlueprint.t() | nil) :: [term()]
  defp correction_rules(nil), do: []
  defp correction_rules(%MissionBlueprint{} = blueprint), do: blueprint.correction_rules

  @spec capability_rules(MissionBlueprint.t() | nil) :: map()
  defp capability_rules(nil), do: %{}
  defp capability_rules(%MissionBlueprint{} = blueprint), do: blueprint.capability_rules

  @spec strategies(MissionBlueprint.t() | nil) :: [atom()]
  defp strategies(%MissionBlueprint{strategies: strategies}), do: Strategies.expand(strategies)
  defp strategies(_blueprint), do: []

  @spec current_step(Plan.t() | nil) :: Step.t() | nil
  defp current_step(nil), do: nil
  defp current_step(%Plan{} = plan), do: Plan.current_step(plan)

  @spec completed_steps(Plan.t() | nil) :: [Step.t()]
  defp completed_steps(nil), do: []
  defp completed_steps(%Plan{} = plan), do: plan.completed_steps

  @spec skipped_steps(Plan.t() | nil) :: [Step.t()]
  defp skipped_steps(nil), do: []
  defp skipped_steps(%Plan{} = plan), do: plan.skipped_steps

  @spec prompt(t()) :: binary()
  defp prompt(%__MODULE__{} = request) do
    """
    You are the alignment judge for a SpectreDirective mission.

    Decide whether the proposed step should continue, skip, pause, ask, revise,
    stop, or finish. Use the mission, current knowledge, available capabilities,
    completed work, and active strategies. Be conservative about risk and
    missing information.

    Mission:
    #{mission_text(request.mission)}

    Active strategies:
    #{list_or_dash(request.strategies)}

    Alignment rules:
    #{rule_text(request.alignment_rules)}

    Correction rules:
    #{rule_text(request.correction_rules)}

    Capability rules:
    #{inspect(request.capability_rules)}

    Mission status:
    #{blank(request.status)}

    Current plan:
    #{plan_text(request.plan)}

    Phase:
    #{request.phase}

    Current step:
    #{step_text(request.current_step)}

    Proposed next step:
    #{step_text(request.next_step)}

    Current knowledge:
    #{knowledge_text(request.knowledge)}

    Available capabilities:
    #{capability_text(request.capabilities)}

    Completed steps:
    #{steps_text(request.completed_steps)}

    Skipped steps:
    #{steps_text(request.skipped_steps)}

    Answer in this exact shape:

    Status: aligned | weakly_aligned | misaligned | unknown | blocked | risky | complete_enough
    Recommendation: continue | skip | revise | ask | pause | stop | finish
    Check: mission_relevance | context_relevance | information_value | confidence | cost | risk | capability | drift | redundancy | strategy
    Score: number from 0.0 to 1.0
    Reason: short explanation
    """
  end

  @spec mission_text(Mission.t() | nil) :: binary()
  defp mission_text(nil), do: "-"

  defp mission_text(%Mission{} = mission) do
    """
    Goal: #{blank(mission.goal)}
    Context: #{blank(mission.context)}
    Success: #{blank(mission.success_criteria)}
    """
    |> String.trim()
  end

  @spec step_text(Step.t() | nil) :: binary()
  defp step_text(nil), do: "-"

  defp step_text(%Step{} = step) do
    """
    Title: #{step.title}
    Kind: #{step.kind}
    Purpose: #{blank(step.purpose)}
    Reason: #{blank(step.reason)}
    Required capability: #{blank(step.required_capability)}
    Risk: #{step.risk}
    Expected output: #{blank(step.expected_output)}
    Done condition: #{blank(step.done_condition)}
    """
    |> String.trim()
  end

  @spec knowledge_text(Knowledge.t()) :: binary()
  defp knowledge_text(%Knowledge{} = knowledge) do
    """
    Known facts:
    #{list_or_dash(knowledge.known_facts)}

    Mission-relevant facts:
    #{list_or_dash(knowledge.mission_relevant_facts)}

    Low-relevance facts:
    #{list_or_dash(knowledge.low_relevance_facts)}

    Decisions:
    #{list_or_dash(knowledge.decisions)}

    Open questions:
    #{list_or_dash(knowledge.open_questions)}

    Confidence:
    #{blank(knowledge.confidence)}
    """
    |> String.trim()
  end

  @spec capability_text(CapabilitySnapshot.t()) :: binary()
  defp capability_text(%CapabilitySnapshot{capabilities: []}), do: "-"

  defp capability_text(%CapabilitySnapshot{} = snapshot) do
    Enum.map_join(snapshot.capabilities, "\n", fn capability ->
      "- #{capability.name}: risk=#{capability.risk}; #{capability.description || "no description"}"
    end)
  end

  @spec steps_text([Step.t()]) :: binary()
  defp steps_text([]), do: "-"

  defp steps_text(steps) do
    Enum.map_join(steps, "\n", fn step ->
      "- #{step.title} (#{step.kind}): #{step.purpose || "no purpose"}"
    end)
  end

  @spec plan_text(Plan.t() | nil) :: binary()
  defp plan_text(nil), do: "-"
  defp plan_text(%Plan{steps: []}), do: "-"

  defp plan_text(%Plan{} = plan) do
    Enum.map_join(plan.steps, "\n", fn step ->
      "- #{step.title} (#{step.status}, #{step.kind}): #{step.purpose || "no purpose"}"
    end)
  end

  @spec rule_text([term()]) :: binary()
  defp rule_text([]), do: "-"
  defp rule_text(rules), do: Enum.map_join(rules, "\n", &"- #{inspect(&1)}")

  @spec list_or_dash([term()]) :: binary()
  defp list_or_dash([]), do: "-"
  defp list_or_dash(values), do: Enum.map_join(values, "\n", &"- #{blank(&1)}")

  @spec blank(term()) :: binary()
  defp blank(nil), do: "-"
  defp blank(value), do: to_string(value)
end
