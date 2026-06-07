defmodule SpectreDirective.Alignment.Result do
  @moduledoc """
  A mission-alignment judgment for one step.
  """

  @type status ::
          :aligned
          | :weakly_aligned
          | :misaligned
          | :unknown
          | :blocked
          | :risky
          | :complete_enough

  @type recommendation :: :continue | :skip | :revise | :ask | :pause | :stop | :finish

  @type t :: %__MODULE__{
          status: status(),
          recommendation: recommendation(),
          reason: binary(),
          phase: :pre_step | :post_step,
          check: atom(),
          score: float() | nil,
          metadata: map()
        }

  defstruct [
    :score,
    status: :unknown,
    recommendation: :continue,
    reason: "Alignment has not been evaluated.",
    phase: :pre_step,
    check: :mission_relevance,
    metadata: %{}
  ]

  @spec new(keyword() | map()) :: t()
  def new(attrs) do
    attrs = Map.new(attrs)
    struct(__MODULE__, attrs)
  end
end
