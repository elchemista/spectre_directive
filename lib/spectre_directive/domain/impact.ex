defmodule SpectreDirective.Impact do
  @moduledoc """
  The consequence of an observation for the mission.

  Impact answers the "so what?" question from `CONCEPT.md`.

  An observation might say "the repository uses Phoenix." The impact for a React
  hiring mission might be "this is weak evidence for frontend fit." The runtime
  stores impact separately so an agent cannot simply collect facts without
  explaining their mission value.
  """

  alias SpectreDirective.ID

  @type t :: %__MODULE__{
          id: binary(),
          step_id: binary() | nil,
          summary: binary(),
          mission_effect: :positive | :negative | :neutral | :unknown,
          confidence_delta: float() | nil,
          evidence: [term()]
        }

  defstruct [:id, :step_id, :summary, :confidence_delta, mission_effect: :unknown, evidence: []]

  @doc """
  Builds an impact record from text, a map, or keyword attributes.
  """
  @spec new(binary() | map() | keyword(), keyword()) :: t()
  def new(impact, opts \\ [])

  def new(summary, opts) when is_binary(summary) do
    new(Keyword.put(opts, :summary, summary), [])
  end

  def new(attrs, opts) when is_map(attrs) or is_list(attrs) do
    attrs = Map.merge(Map.new(attrs), Map.new(opts))

    %__MODULE__{
      id: Map.get(attrs, :id) || ID.new("impact"),
      step_id: Map.get(attrs, :step_id),
      summary: Map.get(attrs, :summary, "Impact is unknown."),
      mission_effect: Map.get(attrs, :mission_effect, :unknown),
      confidence_delta: Map.get(attrs, :confidence_delta),
      evidence: List.wrap(Map.get(attrs, :evidence, []))
    }
  end
end
