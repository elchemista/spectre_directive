defmodule SpectreDirective.Observation do
  @moduledoc """
  What happened after a step, plus the meaning extracted from it.

  Observation is the raw report plus any structured knowledge extracted from
  that report. It answers:

  * what happened?
  * what did we see?
  * what facts, evidence, or open questions came out of the step?

  Observation does not by itself decide whether the plan should change. That is
  represented by `SpectreDirective.Impact` and `SpectreDirective.Correction`.
  Keeping those fields separate makes traces easier to inspect: the mission can
  show the event, why it mattered, and what changed because of it.
  """

  alias SpectreDirective.ID

  @type t :: %__MODULE__{
          id: binary(),
          step_id: binary() | nil,
          summary: binary() | nil,
          raw: term(),
          facts: [term()],
          derived_facts: [term()],
          mission_relevant_facts: [term()],
          low_relevance_facts: [term()],
          decisions: [term()],
          open_questions: [term()],
          evidence: [term()],
          confidence: float() | nil,
          impact: term(),
          correction: term(),
          timestamp: DateTime.t()
        }

  defstruct [
    :id,
    :step_id,
    :summary,
    :raw,
    :impact,
    :correction,
    :confidence,
    facts: [],
    derived_facts: [],
    mission_relevant_facts: [],
    low_relevance_facts: [],
    decisions: [],
    open_questions: [],
    evidence: [],
    timestamp: nil
  ]

  @doc """
  Builds an observation from text, a map, or keyword attributes.
  """
  @spec new(term(), keyword()) :: t()
  def new(observation, opts \\ [])

  def new(summary, opts) when is_binary(summary) do
    new(Keyword.put(opts, :summary, summary))
  end

  def new(attrs, opts) when is_map(attrs) or is_list(attrs) do
    attrs =
      attrs
      |> Map.new()
      |> Map.merge(Map.new(opts))

    %__MODULE__{
      id: Map.get(attrs, :id) || ID.new("obs"),
      step_id: Map.get(attrs, :step_id),
      summary: Map.get(attrs, :summary),
      raw: Map.get(attrs, :raw),
      facts: List.wrap(Map.get(attrs, :facts, [])),
      derived_facts: List.wrap(Map.get(attrs, :derived_facts, [])),
      mission_relevant_facts: List.wrap(Map.get(attrs, :mission_relevant_facts, [])),
      low_relevance_facts: List.wrap(Map.get(attrs, :low_relevance_facts, [])),
      decisions: List.wrap(Map.get(attrs, :decisions, [])),
      open_questions: List.wrap(Map.get(attrs, :open_questions, [])),
      evidence: List.wrap(Map.get(attrs, :evidence, [])),
      confidence: Map.get(attrs, :confidence),
      impact: Map.get(attrs, :impact),
      correction: Map.get(attrs, :correction),
      timestamp: Map.get(attrs, :timestamp) || DateTime.utc_now()
    }
  end
end
