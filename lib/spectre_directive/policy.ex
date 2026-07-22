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

  def call(function, requirement, context, _opts) when is_function(function, 2),
    do: function.(requirement, context)

  def call(function, requirement, context, opts) when is_function(function, 3),
    do: function.(requirement, context, opts)

  def call({module, adapter_opts}, requirement, context, opts)
      when is_atom(module) and is_list(adapter_opts),
      do: module.authorize(requirement, context, Keyword.merge(adapter_opts, opts))

  def call(module, requirement, context, opts) when is_atom(module),
    do: module.authorize(requirement, context, opts)

  def call(target, _requirement, _context, _opts),
    do: {:error, {:invalid_policy_handler, target}}
end
