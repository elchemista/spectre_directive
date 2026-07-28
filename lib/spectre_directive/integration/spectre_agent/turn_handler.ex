defmodule SpectreDirective.Integration.SpectreAgent.TurnHandler do
  @moduledoc false

  alias SpectreDirective.Integration.SpectreAgent
  alias SpectreDirective.Integration.SpectreAgent.Conversation

  @doc false
  @spec handle_turn(term(), keyword()) :: term()
  def handle_turn(request, opts) when is_list(opts) do
    if internal_reason?(request) do
      SpectreAgent.reason_reply(request, opts)
    else
      case Conversation.resume(request.input, request, opts) do
        :cont -> :cont
        {:reply, transition} -> SpectreAgent.turn_reply(transition)
        {:error, _reason} = error -> error
      end
    end
  end

  @spec internal_reason?(term()) :: boolean()
  defp internal_reason?(%{input: %{meta: meta}}) when is_map(meta) do
    Map.get(meta, :spectre_directive_internal) == true or
      Map.get(meta, "spectre_directive_internal") == true
  end

  defp internal_reason?(_request), do: false
end
