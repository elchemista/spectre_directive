defmodule SpectreDirective.Planning.Proposal do
  @moduledoc """
  One proposed guided-planning item.

  Proposals are intentionally plain data so a LiveView, GenServer, CLI, or
  another model process can inspect and edit them before acceptance.
  """

  alias SpectreDirective.ID
  alias SpectreDirective.Step

  @type type :: :strategy | :step | :finish | :correction

  @type t :: %__MODULE__{
          id: binary(),
          type: type(),
          turn: non_neg_integer(),
          prompt: binary() | nil,
          response: binary() | nil,
          strategy: binary() | nil,
          step: Step.t() | nil,
          reason: binary() | nil,
          correction: term(),
          created_at: DateTime.t()
        }

  defstruct [
    :id,
    :type,
    :turn,
    :prompt,
    :response,
    :strategy,
    :step,
    :reason,
    :correction,
    :created_at
  ]

  @doc """
  Builds a proposal from normalized attributes.
  """
  @spec new(map() | keyword()) :: t()
  def new(attrs) do
    attrs = Map.new(attrs)
    type = Map.fetch!(attrs, :type)

    %__MODULE__{
      id: Map.get(attrs, :id) || ID.new("proposal"),
      type: type,
      turn: Map.get(attrs, :turn, 0),
      prompt: Map.get(attrs, :prompt),
      response: Map.get(attrs, :response),
      strategy: Map.get(attrs, :strategy),
      step: normalize_step(Map.get(attrs, :step)),
      reason: Map.get(attrs, :reason),
      correction: Map.get(attrs, :correction),
      created_at: Map.get(attrs, :created_at) || DateTime.utc_now()
    }
  end

  @spec normalize_step(term()) :: Step.t() | nil
  defp normalize_step(nil), do: nil
  defp normalize_step(%Step{} = step), do: step
  defp normalize_step(attrs) when is_map(attrs) or is_list(attrs), do: Step.new(attrs)
end
