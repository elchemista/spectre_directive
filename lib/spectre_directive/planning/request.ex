defmodule SpectreDirective.Planning.Request do
  @moduledoc """
  Planning request passed to a host AI planner.

  This struct keeps the adapter boundary friendly to both sides:

  * agents receive a clear English prompt in `prompt`;
  * host code still has structured mission, knowledge, and capability data when
    it wants to build a richer model request.

  SpectreDirective does not call a model here. The host adapter decides which
  model to use and returns a textual draft.
  """

  alias SpectreDirective.CapabilitySnapshot
  alias SpectreDirective.Knowledge
  alias SpectreDirective.Mission
  alias SpectreDirective.MissionBlueprint
  alias SpectreDirective.Step

  @type t :: %__MODULE__{
          mission: Mission.t(),
          blueprint: MissionBlueprint.t(),
          knowledge: Knowledge.t(),
          capabilities: CapabilitySnapshot.t(),
          prompt: binary(),
          mode: :draft | :guided_strategy | :guided_step,
          generated_steps: [Step.t()],
          turn: pos_integer() | nil,
          strategy: binary() | nil,
          opts: keyword()
        }

  defstruct [
    :mission,
    :blueprint,
    :knowledge,
    :capabilities,
    :prompt,
    :mode,
    :turn,
    :strategy,
    generated_steps: [],
    opts: []
  ]

  @doc """
  Builds a text-first planning request.
  """
  @spec new(MissionBlueprint.t(), Knowledge.t(), CapabilitySnapshot.t(), keyword()) :: t()
  def new(
        %MissionBlueprint{} = blueprint,
        %Knowledge{} = knowledge,
        %CapabilitySnapshot{} = capabilities,
        opts
      )
      when is_list(opts) do
    %__MODULE__{
      mission: blueprint.mission,
      blueprint: blueprint,
      knowledge: knowledge,
      capabilities: capabilities,
      prompt: prompt(blueprint, knowledge, capabilities),
      mode: :draft,
      opts: opts
    }
  end

  @doc """
  Builds a request that asks only for the planning strategy.
  """
  @spec guided_strategy(MissionBlueprint.t(), Knowledge.t(), CapabilitySnapshot.t(), keyword()) ::
          t()
  def guided_strategy(
        %MissionBlueprint{} = blueprint,
        %Knowledge{} = knowledge,
        %CapabilitySnapshot{} = capabilities,
        opts
      )
      when is_list(opts) do
    %__MODULE__{
      mission: blueprint.mission,
      blueprint: blueprint,
      knowledge: knowledge,
      capabilities: capabilities,
      prompt: guided_strategy_prompt(blueprint, knowledge, capabilities),
      mode: :guided_strategy,
      opts: opts
    }
  end

  @doc """
  Builds a request that asks for one next step or finish.
  """
  @spec guided_step(
          MissionBlueprint.t(),
          Knowledge.t(),
          CapabilitySnapshot.t(),
          binary(),
          [Step.t()],
          pos_integer(),
          keyword()
        ) :: t()
  def guided_step(
        %MissionBlueprint{} = blueprint,
        %Knowledge{} = knowledge,
        %CapabilitySnapshot{} = capabilities,
        strategy,
        generated_steps,
        turn,
        opts
      )
      when is_binary(strategy) and is_list(generated_steps) and is_integer(turn) and turn > 0 and
             is_list(opts) do
    %__MODULE__{
      mission: blueprint.mission,
      blueprint: blueprint,
      knowledge: knowledge,
      capabilities: capabilities,
      prompt:
        guided_step_prompt(blueprint, knowledge, capabilities, strategy, generated_steps, turn),
      mode: :guided_step,
      generated_steps: generated_steps,
      turn: turn,
      strategy: strategy,
      opts: opts
    }
  end

  @doc """
  Builds the English prompt used by simple planner adapters.
  """
  @spec prompt(MissionBlueprint.t(), Knowledge.t(), CapabilitySnapshot.t()) :: binary()
  def prompt(%MissionBlueprint{} = blueprint, %Knowledge{} = knowledge, capabilities) do
    """
    You are planning a SpectreDirective mission.

    Write a useful mission plan in normal text. Do not answer with JSON.
    Use short steps. Each step should have a clear title and purpose.

    Mission:
    #{blueprint.mission.goal}

    Context:
    #{blank_to_dash(blueprint.mission.context)}

    Success:
    #{blank_to_dash(blueprint.mission.success_criteria)}

    Known facts:
    #{list_or_dash(knowledge.known_facts)}

    Mission-relevant facts:
    #{list_or_dash(knowledge.mission_relevant_facts)}

    Available capabilities:
    #{capability_list(capabilities)}

    Please answer in this shape:

    Strategy: one short paragraph explaining the plan.

    Plan:
    1. Step title
       kind: observe | investigate | act | verify | summarize | ask | decide | guard | correct | finish
       purpose: why this step helps the mission
       expects: what the step should produce
       capability: optional capability name
       flexibility: locked | guided | optional | agentic
       risk: none | low | medium | high | critical
    """
  end

  @spec guided_strategy_prompt(MissionBlueprint.t(), Knowledge.t(), CapabilitySnapshot.t()) ::
          binary()
  defp guided_strategy_prompt(blueprint, knowledge, capabilities) do
    """
    You are planning a SpectreDirective mission.

    First, decide the planning strategy only. Do not write steps yet.
    Write normal text, one short paragraph.

    Mission:
    #{blueprint.mission.goal}

    Context:
    #{blank_to_dash(blueprint.mission.context)}

    Success:
    #{blank_to_dash(blueprint.mission.success_criteria)}

    Known facts:
    #{list_or_dash(knowledge.known_facts)}

    Mission-relevant facts:
    #{list_or_dash(knowledge.mission_relevant_facts)}

    Available capabilities:
    #{capability_list(capabilities)}

    Answer as:
    Strategy: your strategy paragraph
    """
  end

  @spec guided_step_prompt(
          MissionBlueprint.t(),
          Knowledge.t(),
          CapabilitySnapshot.t(),
          binary(),
          [Step.t()],
          pos_integer()
        ) :: binary()
  defp guided_step_prompt(blueprint, knowledge, capabilities, strategy, generated_steps, turn) do
    """
    You are planning a SpectreDirective mission one step at a time.

    Mission:
    #{blueprint.mission.goal}

    Context:
    #{blank_to_dash(blueprint.mission.context)}

    Success:
    #{blank_to_dash(blueprint.mission.success_criteria)}

    Strategy:
    #{strategy}

    Known facts:
    #{list_or_dash(knowledge.known_facts)}

    Mission-relevant facts:
    #{list_or_dash(knowledge.mission_relevant_facts)}

    Available capabilities:
    #{capability_list(capabilities)}

    Steps already generated:
    #{steps_or_dash(generated_steps)}

    Generate only step #{turn}. If the plan is complete, answer:

    Finish: reason

    Otherwise answer exactly one step in this shape:

    Step: title
    kind: observe | investigate | act | verify | summarize | ask | decide | guard | correct | finish
    purpose: why this step helps the mission
    expects: what the step should produce
    capability: optional capability name
    flexibility: locked | guided | optional | agentic
    risk: none | low | medium | high | critical
    """
  end

  @spec blank_to_dash(binary() | nil) :: binary()
  defp blank_to_dash(nil), do: "-"
  defp blank_to_dash(""), do: "-"
  defp blank_to_dash(value) when is_binary(value), do: value

  @spec list_or_dash([term()]) :: binary()
  defp list_or_dash([]), do: "-"

  defp list_or_dash(values) when is_list(values) do
    Enum.map_join(values, "\n", &"- #{format_value(&1)}")
  end

  @spec capability_list(CapabilitySnapshot.t()) :: binary()
  defp capability_list(%CapabilitySnapshot{capabilities: []}), do: "-"

  defp capability_list(%CapabilitySnapshot{} = snapshot) do
    Enum.map_join(snapshot.capabilities, "\n", fn capability ->
      "- #{capability.name}: #{capability.description || "no description"}"
    end)
  end

  @spec steps_or_dash([Step.t()]) :: binary()
  defp steps_or_dash([]), do: "-"

  defp steps_or_dash(steps) when is_list(steps) do
    Enum.map_join(steps, "\n", fn step ->
      "- #{step.title} (#{step.kind}): #{step.purpose || "no purpose"}"
    end)
  end

  @spec format_value(term()) :: binary()
  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: inspect(value)
end
