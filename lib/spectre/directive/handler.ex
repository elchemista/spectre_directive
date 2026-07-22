defmodule Spectre.Directive.Handler do
  @moduledoc """
  Unified callback implemented by Spectre Agent and GenServer hosts.

  `use Spectre.Directive` installs an overridable default. A host may replace
  it with clauses matching the boundary it owns:

      def handle_directive({:reason, context}, spectre_context), do: decide(context)

      def handle_directive({:invocation, "read_page"}, _context),
        do: {:ok, &MyApp.Pages.read/1}

      def handle_directive({:request, mission_id, request}, state) do
        Spectre.Directive.respond(mission_id, request.id, answer(request))
        {:noreply, state}
      end

  Agent messages receive the Spectre turn context or Directive callback
  context as their second argument. Runtime events receive the owning
  GenServer state. A Spectre Agent reasons for the mission but does not own the
  real user channel: applications resume questions through `reply/3` or a
  correlated `respond/3` call.
  """

  alias SpectreDirective.Context

  @type event :: :request | :information | :assigned | :trace | :error | :outcome
  @type message ::
          {:reason, Context.t()}
          | {:invocation, term()}
          | {event(), binary(), term()}

  @doc "Handles one Directive boundary in the host application."
  @callback handle_directive(message(), host_context :: term()) :: term()
end
