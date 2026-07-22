defmodule SpectreDirective.AgentDecision do
  @moduledoc """
  One normalized choice made by a mission reasoner.
  """

  alias SpectreDirective.Invocation

  @type kind ::
          :invoke
          | :ask
          | :policy
          | :propose_plan
          | :propose_patch
          | :complete_step
          | :complete_mission
          | :blocked

  @type t :: %__MODULE__{
          kind: kind(),
          invocation: Invocation.t() | nil,
          question: term(),
          policy: term(),
          plan: term(),
          patch: term(),
          information: term(),
          result: term(),
          reason: term(),
          metadata: map()
        }

  defstruct [
    :kind,
    :invocation,
    :question,
    :policy,
    :plan,
    :patch,
    :information,
    :result,
    :reason,
    metadata: %{}
  ]

  @kinds [
    :invoke,
    :ask,
    :policy,
    :propose_plan,
    :propose_patch,
    :complete_step,
    :complete_mission,
    :blocked
  ]

  @doc "Normalizes tuple and map decisions returned by host reasoners."
  @spec new(term()) :: {:ok, t()} | {:error, term()}
  def new({:ok, decision}), do: new(decision)
  def new(%__MODULE__{} = decision), do: {:ok, decision}

  def new({:invoke, target}),
    do: {:ok, %__MODULE__{kind: :invoke, invocation: Invocation.new(target)}}

  def new({:invoke, target, opts}) when is_list(opts) or is_map(opts) do
    {:ok, %__MODULE__{kind: :invoke, invocation: Invocation.new(target, opts)}}
  end

  def new({:ask, question}), do: {:ok, %__MODULE__{kind: :ask, question: question}}

  def new({:ask_policy, policy}),
    do: {:ok, %__MODULE__{kind: :policy, policy: policy}}

  def new({:ask_policy, policy, invocation}) do
    {:ok,
     %__MODULE__{
       kind: :policy,
       policy: policy,
       invocation: normalize_invocation(invocation)
     }}
  end

  def new({:propose_plan, plan}), do: {:ok, %__MODULE__{kind: :propose_plan, plan: plan}}

  def new({:propose_patch, patch}),
    do: {:ok, %__MODULE__{kind: :propose_patch, patch: patch}}

  def new({:propose_patch, patch, information}) do
    {:ok, %__MODULE__{kind: :propose_patch, patch: patch, information: information}}
  end

  def new({:complete_step, result}),
    do: {:ok, %__MODULE__{kind: :complete_step, result: result}}

  def new({:complete_mission, result}),
    do: {:ok, %__MODULE__{kind: :complete_mission, result: result}}

  def new({:blocked, reason}), do: {:ok, %__MODULE__{kind: :blocked, reason: reason}}
  def new({:error, reason}), do: new({:blocked, reason})

  def new(attrs) when is_map(attrs) do
    kind = attrs |> value(:kind) |> normalize_kind()

    if kind in @kinds do
      {:ok,
       %__MODULE__{
         kind: kind,
         invocation: normalize_invocation(value(attrs, :invocation) || value(attrs, :target)),
         question: value(attrs, :question),
         policy: value(attrs, :policy),
         plan: value(attrs, :plan),
         patch: value(attrs, :patch),
         information: value(attrs, :information),
         result: value(attrs, :result),
         reason: value(attrs, :reason),
         metadata: Map.new(value(attrs, :metadata, %{}))
       }}
    else
      {:error, {:invalid_agent_decision, attrs}}
    end
  rescue
    error -> {:error, {:invalid_agent_decision, attrs, error}}
  end

  def new(decision), do: {:error, {:invalid_agent_decision, decision}}

  @spec normalize_invocation(term()) :: Invocation.t() | nil
  defp normalize_invocation(nil), do: nil
  defp normalize_invocation(%Invocation{} = invocation), do: invocation

  defp normalize_invocation(attrs) when is_map(attrs) do
    case value(attrs, :target) do
      nil ->
        Invocation.new(attrs)

      target ->
        Invocation.new(target,
          policy: value(attrs, :policy),
          metadata: value(attrs, :metadata, %{})
        )
    end
  end

  defp normalize_invocation(target), do: Invocation.new(target)

  @spec normalize_kind(term()) :: kind() | term()
  defp normalize_kind(kind) when kind in @kinds, do: kind

  defp normalize_kind(kind) when is_binary(kind) do
    Enum.find(@kinds, kind, &(Atom.to_string(&1) == kind))
  end

  defp normalize_kind(kind), do: kind

  @spec value(map(), atom(), term()) :: term()
  defp value(attrs, key, default \\ nil) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, Atom.to_string(key), default)
    end
  end
end
