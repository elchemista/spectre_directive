defmodule Spectre.Directive.Invoker do
  @moduledoc """
  Behaviour and dispatch entry point for application invocation adapters.

  Implement this behaviour when an invocation should be represented by a
  stable module rather than an anonymous function.
  """

  alias SpectreDirective.Context
  alias SpectreDirective.Invoker

  @callback invoke(Context.t(), keyword()) :: term()

  @doc "Invokes a supported function, behaviour module, or MFA target."
  @spec call(Invoker.target(), Context.t()) :: term()
  defdelegate call(target, context), to: Invoker
end
