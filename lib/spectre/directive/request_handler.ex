defmodule Spectre.Directive.RequestHandler do
  @moduledoc """
  Behaviour and dispatch entry point for generic runtime request handlers.

  This adapter is useful when the optional runtime should automatically handle
  questions or confirmations that are not covered by a reasoner or policy.
  """

  alias SpectreDirective.Request
  alias SpectreDirective.RequestHandler

  @callback handle_request(Request.t(), keyword()) :: term()

  @doc "Calls a supported generic request handler."
  @spec call(RequestHandler.target(), Request.t(), keyword()) :: term()
  defdelegate call(target, request, opts \\ []), to: RequestHandler
end
