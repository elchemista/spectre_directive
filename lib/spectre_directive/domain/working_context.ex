defmodule SpectreDirective.WorkingContext do
  @moduledoc """
  Information collected during one live mission.

  This is ordinary mission-local state supplied and owned by the current loop.
  It has no retrieval or persistence semantics.
  """

  alias SpectreDirective.Information

  @type t :: %__MODULE__{
          input: term(),
          assigns: map(),
          information: [Information.t()],
          last_result: term(),
          revision: non_neg_integer()
        }

  defstruct input: nil, assigns: %{}, information: [], last_result: nil, revision: 0

  @doc "Builds a working context."
  @spec new(keyword() | map()) :: t()
  def new(attrs \\ []) do
    attrs = Map.new(attrs)

    information =
      attrs
      |> Map.get(:information, [])
      |> List.wrap()
      |> Enum.map(&Information.new(&1, source: :initial))

    %__MODULE__{
      input: Map.get(attrs, :input),
      assigns: Map.new(Map.get(attrs, :assigns, %{})),
      information: information,
      last_result: Map.get(attrs, :last_result),
      revision: Map.get(attrs, :revision, length(information))
    }
  end

  @doc "Adds one item of information."
  @spec add(t(), term(), keyword()) :: t()
  def add(%__MODULE__{} = context, value, opts \\ []) do
    information = Information.new(value, opts)

    %{
      context
      | information: context.information ++ [information],
        last_result: Keyword.get(opts, :last_result, value),
        revision: context.revision + 1
    }
  end

  @doc "Adds several information values in order."
  @spec add_many(t(), [term()], keyword()) :: t()
  def add_many(context, values, opts \\ [])

  def add_many(%__MODULE__{} = context, [], _opts), do: context

  def add_many(%__MODULE__{} = context, values, opts) when is_list(values) do
    information = Enum.map(values, &Information.new(&1, opts))

    last_result =
      case Keyword.fetch(opts, :last_result) do
        {:ok, value} -> value
        :error -> List.last(values)
      end

    %{
      context
      | information: context.information ++ information,
        last_result: last_result,
        revision: context.revision + length(information)
    }
  end

  @doc "Updates application-owned assigns."
  @spec put_assigns(t(), map()) :: t()
  def put_assigns(%__MODULE__{} = context, assigns) when is_map(assigns) do
    %{context | assigns: Map.merge(context.assigns, assigns), revision: context.revision + 1}
  end
end
