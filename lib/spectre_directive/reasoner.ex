defmodule SpectreDirective.Reasoner do
  @moduledoc """
  Host-owned reasoning boundary for one mission-loop decision.

  A reasoner may call any LLM or agent runtime. It returns a normalized
  `SpectreDirective.AgentDecision` shape; SpectreDirective does not know which
  provider or tool syntax was used.
  """

  alias SpectreDirective.Context

  @type target ::
          (Context.t() -> term())
          | (Context.t(), keyword() -> term())
          | module()
          | {module(), keyword()}

  @callback decide(Context.t(), keyword()) :: term()

  @doc "Calls a configured reasoner target. Call this only from a supervised worker."
  @spec call(target(), Context.t(), keyword()) :: term()
  def call(target, context, opts \\ [])

  def call(function, %Context{} = context, _opts) when is_function(function, 1),
    do: function.(context)

  def call(function, %Context{} = context, opts) when is_function(function, 2),
    do: function.(context, opts)

  def call({module, adapter_opts}, %Context{} = context, opts)
      when is_atom(module) and is_list(adapter_opts),
      do: module.decide(context, Keyword.merge(adapter_opts, opts))

  def call(module, %Context{} = context, opts) when is_atom(module),
    do: module.decide(context, opts)

  def call(target, %Context{}, _opts), do: {:error, {:invalid_reasoner, target}}
end
