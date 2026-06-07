defmodule SpectreDirective.Knowledge do
  @moduledoc """
  Layered knowledge collected and derived during a mission.

  Knowledge is intentionally structured instead of being a single text blob.
  The runtime uses separate layers so alignment can ask whether information
  matters for the current mission:

  * `known_facts` are facts already known or recalled.
  * `assumptions` are mission context that may need verification.
  * `observations` are raw step results.
  * `derived_facts` are meaning extracted from observations.
  * `mission_relevant_facts` directly affect success.
  * `low_relevance_facts` may be true but should not pull the mission away.
  * `decisions` capture what changed because of new information.

  Example: "repository uses Phoenix" may be a known fact, while "weak evidence
  for React frontend fit" is the mission-relevant fact in a React hiring mission.
  """

  alias SpectreDirective.Mission
  alias SpectreDirective.Observation

  @type t :: %__MODULE__{
          known_facts: [term()],
          assumptions: [term()],
          missing_information: [term()],
          observations: [Observation.t()],
          derived_facts: [term()],
          mission_relevant_facts: [term()],
          low_relevance_facts: [term()],
          decisions: [term()],
          confidence: float() | nil,
          open_questions: [term()],
          recalled: term()
        }

  defstruct known_facts: [],
            assumptions: [],
            missing_information: [],
            observations: [],
            derived_facts: [],
            mission_relevant_facts: [],
            low_relevance_facts: [],
            decisions: [],
            confidence: nil,
            open_questions: [],
            recalled: nil

  @doc """
  Builds an empty or mission-seeded knowledge snapshot.
  """
  @spec new(Mission.t() | keyword() | map() | nil) :: t()
  def new(nil), do: %__MODULE__{}

  def new(%Mission{} = mission) do
    %__MODULE__{
      assumptions: Enum.reject([mission.context], &is_nil/1),
      missing_information: [],
      mission_relevant_facts: Enum.reject([mission.success_criteria], &is_nil/1)
    }
  end

  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs)
    struct(__MODULE__, attrs)
  end

  @doc """
  Adds recalled memory to the knowledge snapshot.
  """
  @spec merge_recall(t(), term()) :: t()
  def merge_recall(%__MODULE__{} = knowledge, nil), do: knowledge

  def merge_recall(%__MODULE__{} = knowledge, recall) do
    %{knowledge | recalled: recall, known_facts: knowledge.known_facts ++ recall_facts(recall)}
  end

  @doc """
  Records a new observation and updates all derived knowledge layers.
  """
  @spec record_observation(t(), Observation.t()) :: t()
  def record_observation(%__MODULE__{} = knowledge, %Observation{} = observation) do
    %{
      knowledge
      | observations: knowledge.observations ++ [observation],
        known_facts: knowledge.known_facts ++ observation.facts,
        derived_facts: knowledge.derived_facts ++ observation.derived_facts,
        mission_relevant_facts:
          knowledge.mission_relevant_facts ++ observation.mission_relevant_facts,
        low_relevance_facts: knowledge.low_relevance_facts ++ observation.low_relevance_facts,
        decisions: knowledge.decisions ++ observation.decisions,
        open_questions: Enum.uniq(knowledge.open_questions ++ observation.open_questions),
        confidence: observation.confidence || knowledge.confidence
    }
  end

  @spec recall_facts(term()) :: [term()]
  defp recall_facts(%{moments: moments}) when is_list(moments) do
    Enum.map(moments, fn moment ->
      Map.get(moment, :text) || Map.get(moment, "text") || inspect(moment)
    end)
  end

  defp recall_facts(%{results: results}) when is_list(results), do: Enum.map(results, &inspect/1)
  defp recall_facts(list) when is_list(list), do: list
  defp recall_facts(_recall), do: []
end
