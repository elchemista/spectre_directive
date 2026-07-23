defmodule SpectreDirective.Integration.SpectreAgent.TurnHandler do
  @moduledoc false

  alias SpectreDirective.Integration.SpectreAgent
  alias SpectreDirective.Integration.SpectreAgent.Conversation

  @doc false
  @spec handle_turn(term(), keyword()) :: term()
  def handle_turn(request, opts) when is_list(opts) do
    case Conversation.resume(request.input, request, opts) do
      :cont -> :cont
      {:reply, transition} -> SpectreAgent.turn_reply(transition)
      {:error, _reason} = error -> error
    end
  end
end
