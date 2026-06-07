defmodule SpectreDirective.Mission do
  @moduledoc """
  The high-level thing a directive is trying to achieve.
  """

  alias SpectreDirective.ID

  @type status ::
          :draft | :running | :paused | :waiting | :blocked | :finished | :stopped | :aborted

  @type t :: %__MODULE__{
          id: binary(),
          goal: binary(),
          context: binary() | nil,
          success_criteria: binary() | nil,
          constraints: [term()],
          risk_boundaries: [term()],
          memory_scope: term(),
          status: status(),
          metadata: map()
        }

  defstruct [
    :id,
    :goal,
    :context,
    :success_criteria,
    :memory_scope,
    status: :draft,
    constraints: [],
    risk_boundaries: [],
    metadata: %{}
  ]

  @doc """
  Builds a mission from a goal, attribute map, keyword list, or existing mission.
  """
  @spec new(binary() | map() | keyword() | t(), keyword()) :: t()
  def new(mission, opts \\ [])

  def new(%__MODULE__{} = mission, opts) do
    mission
    |> Map.put(:id, mission.id || Keyword.get(opts, :id) || ID.new("mission"))
    |> Map.put(:status, Keyword.get(opts, :status, mission.status || :draft))
  end

  def new(goal, opts) when is_binary(goal) do
    new(
      %__MODULE__{
        goal: goal,
        context: Keyword.get(opts, :context),
        success_criteria: Keyword.get(opts, :success),
        constraints: List.wrap(Keyword.get(opts, :constraints, [])),
        risk_boundaries: List.wrap(Keyword.get(opts, :risk_boundaries, [])),
        memory_scope: Keyword.get(opts, :memory_scope),
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
        goal: attr(attrs, :goal),
        context: attr(attrs, :context),
        success_criteria: attr(attrs, [:success_criteria, :success]),
        constraints: List.wrap(attr(attrs, :constraints, [])),
        risk_boundaries: List.wrap(attr(attrs, :risk_boundaries, [])),
        memory_scope: attr(attrs, :memory_scope),
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
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key)) || default
  end
end
