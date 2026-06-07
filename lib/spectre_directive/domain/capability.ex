defmodule SpectreDirective.Capability do
  @moduledoc """
  Something the agent can realistically do in this situation.
  """

  alias SpectreDirective.ID

  @type risk :: :none | :low | :medium | :high | :critical

  @type t :: %__MODULE__{
          id: binary(),
          name: atom() | binary(),
          description: binary() | nil,
          source: atom() | module() | nil,
          risk: risk(),
          requires_approval?: boolean(),
          cost: term(),
          expected_output_type: term(),
          available?: boolean(),
          executor: nil | {module(), atom(), list()},
          metadata: map()
        }

  defstruct [
    :id,
    :name,
    :description,
    :source,
    :cost,
    :expected_output_type,
    :executor,
    risk: :low,
    requires_approval?: false,
    available?: true,
    metadata: %{}
  ]

  @doc """
  Builds a capability from a name or attribute payload.
  """
  @spec new(atom() | binary() | keyword() | map()) :: t()
  def new(name) when is_atom(name) or is_binary(name), do: new(%{name: name})

  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs)

    %__MODULE__{
      id: Map.get(attrs, :id) || ID.new("cap"),
      name: Map.fetch!(attrs, :name),
      description: Map.get(attrs, :description),
      source: Map.get(attrs, :source),
      risk: Map.get(attrs, :risk, :low),
      requires_approval?: Map.get(attrs, :requires_approval?, false),
      cost: Map.get(attrs, :cost),
      expected_output_type: Map.get(attrs, :expected_output_type),
      available?: Map.get(attrs, :available?, true),
      executor: Map.get(attrs, :executor),
      metadata: Map.new(Map.get(attrs, :metadata, %{}))
    }
  end
end
