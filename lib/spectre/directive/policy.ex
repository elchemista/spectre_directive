defmodule Spectre.Directive.Policy do
  @moduledoc """
  Behaviour and dispatch entry point for host-owned policy decisions.

  Directive treats requirements and policy responses as application data.
  """

  alias SpectreDirective.Context
  alias SpectreDirective.Policy

  @callback authorize(term(), Context.t(), keyword()) :: term()

  @doc "Calls a supported policy target for one opaque requirement."
  @spec call(Policy.target(), term(), Context.t(), keyword()) :: term()
  defdelegate call(target, requirement, context, opts \\ []), to: Policy
end
