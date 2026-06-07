defmodule SpectreDirective.Correction do
  @moduledoc """
  A first-class change to the living plan.

  A correction type says what changed. A correction strategy says why that kind
  of change is appropriate: tactical, strategic, scope, evidence, cost, risk,
  confidence, or drift.

  Corrections are emitted after observations or alignment checks. They can
  finish early, abort, add steps, remove stale steps, or simply record that the
  current plan should continue.
  """

  alias SpectreDirective.ID

  @type kind ::
          :continue
          | :skip_step
          | :remove_steps
          | :add_step
          | :replace_step
          | :reorder_steps
          | :narrow_scope
          | :expand_scope
          | :ask_user
          | :wait
          | :retry
          | :delegate
          | :finish_early
          | :abort

  @type strategy ::
          :tactical
          | :strategic
          | :scope
          | :evidence
          | :cost
          | :risk
          | :confidence
          | :drift

  @type t :: %__MODULE__{
          id: binary(),
          type: kind(),
          strategy: strategy(),
          reason: binary(),
          changes: map(),
          source: atom(),
          timestamp: DateTime.t()
        }

  defstruct [
    :id,
    :reason,
    type: :continue,
    strategy: :tactical,
    changes: %{},
    source: :alignment,
    timestamp: nil
  ]

  @doc """
  Builds a correction from a correction type, map, or keyword attributes.
  """
  @spec new(kind() | map() | keyword(), keyword()) :: t()
  def new(correction, opts \\ [])

  def new(type, opts) when is_atom(type), do: new(Keyword.put(opts, :type, type), [])

  def new(attrs, opts) when is_map(attrs) or is_list(attrs) do
    attrs = Map.merge(Map.new(attrs), Map.new(opts))

    %__MODULE__{
      id: Map.get(attrs, :id) || ID.new("corr"),
      type: Map.get(attrs, :type, :continue),
      strategy: Map.get(attrs, :strategy, :tactical),
      reason: Map.get(attrs, :reason, "Continue with the current plan."),
      changes: Map.new(Map.get(attrs, :changes, %{})),
      source: Map.get(attrs, :source, :alignment),
      timestamp: Map.get(attrs, :timestamp) || DateTime.utc_now()
    }
  end
end
