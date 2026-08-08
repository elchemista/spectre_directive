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

  def call(target, %Context{} = context, opts) when is_list(opts) do
    if Keyword.keyword?(opts),
      do: dispatch(target, context, opts),
      else: {:error, {:invalid_reasoner_options, opts}}
  end

  def call(_target, %Context{}, opts), do: {:error, {:invalid_reasoner_options, opts}}

  @spec dispatch(target(), Context.t(), keyword()) :: term()
  defp dispatch(function, %Context{} = context, _opts) when is_function(function, 1),
    do: function.(context)

  defp dispatch(function, %Context{} = context, opts) when is_function(function, 2),
    do: function.(context, opts)

  defp dispatch({module, adapter_opts} = target, %Context{} = context, opts)
       when is_atom(module) and is_list(adapter_opts) do
    if Keyword.keyword?(adapter_opts),
      do: module.decide(context, Keyword.merge(adapter_opts, opts)),
      else: {:error, {:invalid_reasoner, target}}
  end

  defp dispatch(module, %Context{} = context, opts) when is_atom(module),
    do: module.decide(context, opts)

  defp dispatch(target, %Context{}, _opts), do: {:error, {:invalid_reasoner, target}}
end
