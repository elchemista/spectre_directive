defmodule SpectreDirective.Step do
  @moduledoc """
  One unit of intent in a living plan.

  A step may contain a trusted invocation target. If it does not, the reasoner
  decides what information or action is needed next. An invocation never
  mutates loop state directly; its return value is interpreted by the engine.
  """

  alias SpectreDirective.ID

  @type kind :: :observe | :investigate | :act | :verify | :summarize | :ask | :decide | atom()
  @type status :: :pending | :running | :completed | :skipped | :blocked | :failed
  @type flexibility :: :locked | :guided | :optional | :agentic
  @type source :: :authored | :generated | :user_added

  @type t :: %__MODULE__{
          id: binary(),
          title: binary(),
          kind: kind(),
          purpose: binary() | nil,
          reason: binary() | nil,
          input: term(),
          expected_output: term(),
          done_condition: term(),
          invoke: term(),
          policy: term(),
          risk: atom(),
          status: status(),
          owner: term(),
          attempts: non_neg_integer(),
          evidence: [term()],
          result: term(),
          source: source(),
          flexibility: flexibility(),
          prompt: binary() | nil,
          metadata: map()
        }

  defstruct [
    :id,
    :title,
    :purpose,
    :reason,
    :input,
    :expected_output,
    :done_condition,
    :invoke,
    :policy,
    :owner,
    :result,
    :prompt,
    kind: :investigate,
    risk: :low,
    status: :pending,
    attempts: 0,
    evidence: [],
    source: :authored,
    flexibility: :guided,
    metadata: %{}
  ]

  @doc "Builds a step from a title or attributes."
  @spec new(binary() | map() | keyword() | t(), keyword()) :: t()
  def new(step, opts \\ [])

  def new(%__MODULE__{} = step, opts) do
    attrs = Map.merge(Map.from_struct(step), Map.new(opts))
    build(attrs)
  end

  def new(title, opts) when is_binary(title), do: build(Map.put(Map.new(opts), :title, title))

  def new(attrs, opts) when is_map(attrs) or is_list(attrs) do
    attrs |> Map.new() |> Map.merge(Map.new(opts)) |> build()
  end

  @spec build(map()) :: t()
  defp build(attrs) do
    %__MODULE__{
      id: value(attrs, :id) || ID.new("step"),
      title: value(attrs, :title) || "Untitled step",
      kind: value(attrs, :kind, :investigate),
      purpose: value(attrs, :purpose),
      reason: value(attrs, :reason),
      input: value(attrs, :input),
      expected_output: value(attrs, [:expected_output, :expects]),
      done_condition: value(attrs, [:done_condition, :done_when]),
      invoke: value(attrs, [:invoke, :invocation]),
      policy: value(attrs, :policy),
      risk: value(attrs, :risk, :low),
      status: value(attrs, :status, :pending),
      owner: value(attrs, :owner),
      attempts: value(attrs, :attempts, 0),
      evidence: List.wrap(value(attrs, :evidence, [])),
      result: value(attrs, :result),
      source: value(attrs, :source, :authored),
      flexibility: value(attrs, :flexibility, :guided),
      prompt: value(attrs, :prompt),
      metadata: Map.new(value(attrs, :metadata, %{}))
    }
  end

  @spec value(map(), atom() | [atom()], term()) :: term()
  defp value(attrs, key_or_keys, default \\ nil)

  defp value(attrs, keys, default) when is_list(keys),
    do: Enum.find_value(keys, default, &value(attrs, &1))

  defp value(attrs, key, default) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, Atom.to_string(key), default)
    end
  end
end
