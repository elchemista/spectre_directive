defmodule SpectreDirective.Step do
  @moduledoc """
  One executable or monitorable piece of a living plan.

  A step is more than an action name. It carries intent:

  * `purpose` says why this work helps the mission.
  * `reason` explains why this step exists now.
  * `expected_output` and `done_condition` help an agent know when to stop.
  * `risk` and `required_capability` feed pre-step alignment.
  * `flexibility` tells the planner how free it is to skip or adapt the step.

  Good step:

      Step.new("Search frontend evidence",
        kind: :investigate,
        purpose: "Find React, TypeScript, UI, and frontend evidence",
        expected_output: "Frontend-related repositories or absence of evidence",
        flexibility: :agentic
      )
  """

  alias SpectreDirective.ID

  @type kind ::
          :remember
          | :observe
          | :investigate
          | :act
          | :verify
          | :summarize
          | :ask
          | :decide
          | :guard
          | :correct
          | :finish
  @type status :: :pending | :running | :completed | :skipped | :blocked | :failed
  @type flexibility :: :locked | :guided | :optional | :agentic

  @type t :: %__MODULE__{
          id: binary(),
          title: binary(),
          kind: kind(),
          purpose: binary() | nil,
          reason: binary() | nil,
          required_capability: atom() | binary() | nil,
          input: term(),
          expected_output: binary() | nil,
          done_condition: binary() | nil,
          risk: atom(),
          status: status(),
          owner: term(),
          attempts: non_neg_integer(),
          evidence: [term()],
          result: term(),
          source: :authored | :generated | :correction_added | :user_added,
          flexibility: flexibility(),
          prompt: binary() | nil,
          metadata: map()
        }

  defstruct [
    :id,
    :title,
    :purpose,
    :reason,
    :required_capability,
    :input,
    :expected_output,
    :done_condition,
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

  @doc """
  Builds a step from a title, attribute map, or keyword list.
  """
  @spec new(binary() | map() | keyword(), keyword()) :: t()
  def new(step, opts \\ [])

  def new(title, opts) when is_binary(title) do
    new(Keyword.put(opts, :title, title), [])
  end

  def new(attrs, opts) when is_map(attrs) or is_list(attrs) do
    attrs = Map.merge(Map.new(attrs), Map.new(opts))

    %__MODULE__{
      id: Map.get(attrs, :id) || ID.new("step"),
      title: Map.get(attrs, :title) || "Untitled step",
      kind: Map.get(attrs, :kind, :investigate),
      purpose: Map.get(attrs, :purpose),
      reason: Map.get(attrs, :reason),
      required_capability: Map.get(attrs, :required_capability) || Map.get(attrs, :capability),
      input: Map.get(attrs, :input),
      expected_output: Map.get(attrs, :expected_output) || Map.get(attrs, :expects),
      done_condition: Map.get(attrs, :done_condition) || Map.get(attrs, :done_when),
      risk: Map.get(attrs, :risk, :low),
      status: Map.get(attrs, :status, :pending),
      owner: Map.get(attrs, :owner),
      attempts: Map.get(attrs, :attempts, 0),
      evidence: List.wrap(Map.get(attrs, :evidence, [])),
      result: Map.get(attrs, :result),
      source: Map.get(attrs, :source, :authored),
      flexibility: Map.get(attrs, :flexibility, :guided),
      prompt: Map.get(attrs, :prompt),
      metadata: Map.new(Map.get(attrs, :metadata, %{}))
    }
  end
end
