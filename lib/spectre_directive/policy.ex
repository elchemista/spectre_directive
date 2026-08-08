defmodule SpectreDirective.Policy do
  @moduledoc """
  Optional host policy boundary used by the local runtime.

  The policy requirement is opaque to SpectreDirective. A handler returns a
  value such as `:allow`, `:deny`, or any application decision that a manual
  host can pass back to the engine.
  """

  alias SpectreDirective.Context

  @type target ::
          (term(), Context.t() -> term())
          | (term(), Context.t(), keyword() -> term())
          | module()
          | {module(), keyword()}

  @callback authorize(term(), Context.t(), keyword()) :: term()

  @doc "Calls a configured policy handler from a worker process."
  @spec call(target(), term(), Context.t(), keyword()) :: term()
  def call(target, requirement, context, opts \\ [])

  def call(target, requirement, %Context{} = context, opts) when is_list(opts) do
    if Keyword.keyword?(opts),
      do: dispatch(target, requirement, context, opts),
      else: {:error, {:invalid_policy_options, opts}}
  end

  def call(_target, _requirement, %Context{}, opts),
    do: {:error, {:invalid_policy_options, opts}}

  @spec dispatch(target(), term(), Context.t(), keyword()) :: term()
  defp dispatch(function, requirement, context, _opts) when is_function(function, 2),
    do: function.(requirement, context)

  defp dispatch(function, requirement, context, opts) when is_function(function, 3),
    do: function.(requirement, context, opts)

  defp dispatch({module, adapter_opts} = target, requirement, context, opts)
       when is_atom(module) and is_list(adapter_opts) do
    if Keyword.keyword?(adapter_opts),
      do: module.authorize(requirement, context, Keyword.merge(adapter_opts, opts)),
      else: {:error, {:invalid_policy_handler, target}}
  end

  defp dispatch(module, requirement, context, opts) when is_atom(module),
    do: module.authorize(requirement, context, opts)

  defp dispatch(target, _requirement, _context, _opts),
    do: {:error, {:invalid_policy_handler, target}}
end
