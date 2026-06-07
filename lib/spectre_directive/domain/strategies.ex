defmodule SpectreDirective.Strategies do
  @moduledoc """
  Primitive strategies and presets that shape correction behavior.
  """

  @primitive [
    :observe_before_act,
    :verify_after_act,
    :pause_before_impact,
    :inspect_before_modify,
    :small_safe_moves,
    :mission_relevance_first,
    :evidence_before_judgment,
    :finish_when_enough,
    :learn_every_step,
    :correct_direction
  ]

  @presets %{
    safe_operator: [
      :observe_before_act,
      :pause_before_impact,
      :verify_after_act,
      :small_safe_moves
    ],
    careful_modifier: [
      :inspect_before_modify,
      :small_safe_moves,
      :verify_after_act,
      :pause_before_impact
    ],
    focused_research: [
      :mission_relevance_first,
      :evidence_before_judgment,
      :correct_direction,
      :finish_when_enough
    ],
    deep_research: [
      :mission_relevance_first,
      :evidence_before_judgment,
      :correct_direction,
      :verify_after_act
    ],
    fast_check: [
      :observe_before_act,
      :mission_relevance_first,
      :finish_when_enough,
      :small_safe_moves
    ],
    qa_flow: [
      :observe_before_act,
      :verify_after_act,
      :small_safe_moves,
      :learn_every_step,
      :finish_when_enough
    ],
    hiring_fit: [
      :mission_relevance_first,
      :evidence_before_judgment,
      :correct_direction,
      :finish_when_enough
    ],
    lead_qualification: [
      :mission_relevance_first,
      :evidence_before_judgment,
      :finish_when_enough,
      :correct_direction
    ]
  }

  @doc """
  Returns primitive strategy names.
  """
  @spec primitive() :: [atom()]
  def primitive, do: @primitive

  @doc """
  Returns strategy presets and their primitive members.
  """
  @spec presets() :: map()
  def presets, do: @presets

  @doc """
  Expands presets into primitive strategies.
  """
  @spec expand([atom()]) :: [atom()]
  def expand(strategies) do
    strategies
    |> Enum.flat_map(fn strategy -> Map.get(@presets, strategy, [strategy]) end)
    |> Enum.uniq()
  end
end
