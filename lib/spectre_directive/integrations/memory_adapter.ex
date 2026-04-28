defmodule SpectreDirective.MemoryAdapter do
  # credo:disable-for-this-file Credo.Check.Refactor.Apply
  @moduledoc """
  Optional SpectreMnemonic event sink.
  """

  @doc """
  Records one event through a configured adapter or optional SpectreMnemonic.

  Missing or failing memory integrations are intentionally non-fatal.
  """
  @spec record(SpectreDirective.Event.t(), keyword()) :: :ok
  def record(event, opts \\ []) do
    adapter =
      Keyword.get(opts, :adapter) || Application.get_env(:spectre_directive, :memory_adapter)

    cond do
      adapter && Code.ensure_loaded?(adapter) && function_exported?(adapter, :record, 2) ->
        _ = adapter.record(event, opts)
        :ok

      Code.ensure_loaded?(SpectreMnemonic) ->
        # Keep this optional integration free of a compile-time dependency.
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        _ =
          apply(SpectreMnemonic, :signal, [
            event.payload,
            [
              stream: :spectre_directive,
              task_id: event.task_id,
              kind: event.type,
              metadata: %{event_id: event.id, timestamp: event.timestamp}
            ]
          ])

        :ok

      true ->
        :ok
    end
  rescue
    _ -> :ok
  end
end
