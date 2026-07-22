defmodule SpectreDirective.Mission do
  @moduledoc """
  The objective and completion contract for one mission-loop run.

  A mission contains durable intent, not execution state owned by callbacks.
  Live status is advanced only by `SpectreDirective.Loop.Engine`.
  """

  alias SpectreDirective.ID

  @type status ::
          :draft
          | :running
          | :waiting
          | :paused
          | :blocked
          | :completed
          | :failed
          | :cancelled

  @type t :: %__MODULE__{
          id: binary(),
          goal: term(),
          context: term(),
          success_criteria: term(),
          constraints: [term()],
          risk_boundaries: [term()],
          status: status(),
          metadata: map()
        }

  @type executable_t :: %__MODULE__{goal: binary()}

  defstruct [
    :id,
    :goal,
    :context,
    :success_criteria,
    status: :draft,
    constraints: [],
    risk_boundaries: [],
    metadata: %{}
  ]

  @doc "Builds a mission from a goal, attributes, or an existing mission."
  @spec new(binary() | map() | keyword() | t(), keyword()) :: t()
  def new(mission, opts \\ [])

  def new(%__MODULE__{} = mission, opts) do
    %{
      mission
      | id: mission.id || Keyword.get(opts, :id) || ID.new("mission"),
        status: Keyword.get(opts, :status, mission.status || :draft)
    }
  end

  def new(goal, opts) when is_binary(goal) do
    new(
      %__MODULE__{
        goal: goal,
        context: Keyword.get(opts, :context),
        success_criteria: Keyword.get(opts, :success) || Keyword.get(opts, :success_criteria),
        constraints: List.wrap(Keyword.get(opts, :constraints, [])),
        risk_boundaries: List.wrap(Keyword.get(opts, :risk_boundaries, [])),
        metadata: Map.new(Keyword.get(opts, :metadata, %{}))
      },
      opts
    )
  end

  def new(attrs, opts) when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs)

    new(
      %__MODULE__{
        id: attr(attrs, :id),
        goal: attr(attrs, [:goal, :mission, :objective]),
        context: attr(attrs, :context),
        success_criteria: attr(attrs, [:success_criteria, :success]),
        constraints: List.wrap(attr(attrs, :constraints, [])),
        risk_boundaries: List.wrap(attr(attrs, :risk_boundaries, [])),
        status: attr(attrs, :status, :draft),
        metadata: Map.new(attr(attrs, :metadata, %{}))
      },
      opts
    )
  end

  @spec attr(map(), atom() | [atom()], term()) :: term()
  defp attr(attrs, key_or_keys, default \\ nil)

  defp attr(attrs, keys, default) when is_list(keys) do
    Enum.find_value(keys, default, &attr(attrs, &1))
  end

  defp attr(attrs, key, default) when is_atom(key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, Atom.to_string(key), default)
    end
  end
end
