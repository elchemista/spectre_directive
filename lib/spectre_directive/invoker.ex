defmodule SpectreDirective.Invoker do
  @moduledoc """
  Behaviour and local dispatch helper for invocation targets.

  Anonymous functions are ideal for live local missions. Behaviour modules and
  MFA tuples are stable, inspectable targets for application integrations.
  """

  alias SpectreDirective.Context

  @type result :: term()
  @type target ::
          (Context.t() -> result())
          | module()
          | {module(), keyword()}
          | {module(), atom()}
          | {module(), atom(), list()}

  @callback invoke(Context.t(), keyword()) :: result()

  @doc "Invokes a supported target. Call this only from a supervised worker."
  @spec call(target(), Context.t()) :: result()
  def call(target, context)

  def call(function, %Context{} = context) when is_function(function, 1),
    do: function.(context)

  def call({module, opts}, %Context{} = context) when is_atom(module) and is_list(opts),
    do: module.invoke(context, opts)

  def call({module, function}, %Context{} = context)
      when is_atom(module) and is_atom(function),
      do: apply(module, function, [context])

  def call({module, function, extra_args}, %Context{} = context)
      when is_atom(module) and is_atom(function) and is_list(extra_args),
      do: apply(module, function, [context | extra_args])

  def call(module, %Context{} = context) when is_atom(module), do: module.invoke(context, [])

  def call(target, %Context{}), do: {:error, {:invalid_invocation_target, target}}
end
