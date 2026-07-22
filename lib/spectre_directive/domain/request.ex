defmodule SpectreDirective.Request do
  @moduledoc """
  A correlated external request emitted by the pure mission engine.
  """

  alias SpectreDirective.Context
  alias SpectreDirective.ID

  @type kind :: :reason | :invoke | :question | :policy | :confirmation

  @type t :: %__MODULE__{
          id: binary(),
          kind: kind(),
          mission_id: binary(),
          step_id: binary() | nil,
          plan_version: pos_integer(),
          context_revision: non_neg_integer(),
          target: term(),
          context: Context.t(),
          payload: map(),
          created_at: DateTime.t()
        }

  defstruct [
    :id,
    :kind,
    :mission_id,
    :step_id,
    :plan_version,
    :context_revision,
    :target,
    :context,
    :created_at,
    payload: %{}
  ]

  @doc "Builds a request from a loop context."
  @spec new(kind(), Context.t(), keyword()) :: t()
  def new(kind, %Context{} = context, opts \\ []) do
    %__MODULE__{
      id: Keyword.get(opts, :id) || ID.new("request"),
      kind: kind,
      mission_id: context.mission.id,
      step_id: context.step && context.step.id,
      plan_version: context.plan.version,
      context_revision: context.revision,
      target: Keyword.get(opts, :target),
      context: context,
      payload: Map.new(Keyword.get(opts, :payload, %{})),
      created_at: DateTime.utc_now()
    }
  end
end
