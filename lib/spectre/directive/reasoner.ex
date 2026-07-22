defmodule Spectre.Directive.Reasoner do
  @moduledoc """
  Behaviour and dispatch entry point for provider-neutral mission reasoners.

  A reasoner returns one decision understood by `SpectreDirective.AgentDecision`.
  """

  alias SpectreDirective.Context
  alias SpectreDirective.Reasoner

  @callback decide(Context.t(), keyword()) :: term()

  @doc "Calls a supported reasoner target with callback context and options."
  @spec call(Reasoner.target(), Context.t(), keyword()) :: term()
  defdelegate call(target, context, opts \\ []), to: Reasoner
end
