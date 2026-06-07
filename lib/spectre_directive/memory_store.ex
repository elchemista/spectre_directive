defmodule SpectreDirective.MemoryStore do
  @moduledoc """
  Runtime memory boundary for missions.

  SpectreDirective itself does not depend on a concrete memory system. Memory is
  an adapter boundary so a host app can use SpectreMnemonic, a database, a test
  fake, or no memory at all.

  A memory adapter receives the mission before planning starts and receives a
  meaningful record after each completed step:

      defmodule MyApp.DirectiveMemory do
        @behaviour SpectreDirective.MemoryStore

        @impl SpectreDirective.MemoryStore
        def recall(mission, _opts) do
          MyMemory.search(mission.goal, scope: mission.memory_scope)
        end

        @impl SpectreDirective.MemoryStore
        def remember(record, _opts) do
          MyMemory.store(%{
            mission: record.mission,
            observation: record.observation,
            impact: record.impact,
            correction: record.correction
          })
        end
      end

  If no adapter is configured, recall returns `nil` and remember is a no-op.
  Adapter failures are swallowed into no-memory behavior because memory should
  improve mission quality without becoming a hard runtime dependency.
  """

  alias SpectreDirective.Mission

  @callback recall(Mission.t(), keyword()) :: {:ok, term()} | {:error, term()} | term()
  @callback remember(term(), keyword()) :: :ok | {:ok, term()} | {:error, term()}

  @doc """
  Recalls mission memory through the configured memory adapter.
  """
  @spec recall(Mission.t(), keyword()) :: term()
  def recall(%Mission{} = mission, opts) do
    opts
    |> Keyword.get(:memory_adapter)
    |> recall_with_adapter(mission, opts)
  end

  @doc """
  Stores meaningful mission memory through the configured memory adapter.
  """
  @spec remember(term(), keyword()) :: :ok
  def remember(record, opts) do
    opts
    |> Keyword.get(:memory_adapter)
    |> remember_with_adapter(record, opts)

    :ok
  end

  @spec recall_with_adapter(module() | nil, Mission.t(), keyword()) :: term()
  defp recall_with_adapter(nil, _mission, _opts), do: nil
  defp recall_with_adapter(:none, _mission, _opts), do: nil

  defp recall_with_adapter(adapter, mission, opts) when is_atom(adapter) do
    memory_opts = Keyword.get(opts, :memory_opts, opts)

    case recall_adapter(adapter, mission, memory_opts) do
      {:ok, recall} -> recall
      {:error, _reason} -> nil
      other -> other
    end
  end

  defp recall_with_adapter(_adapter, _mission, _opts), do: nil

  @spec remember_with_adapter(module() | nil, term(), keyword()) :: :ok
  defp remember_with_adapter(nil, _record, _opts), do: :ok
  defp remember_with_adapter(:none, _record, _opts), do: :ok

  defp remember_with_adapter(adapter, record, opts) when is_atom(adapter) do
    memory_opts = Keyword.get(opts, :memory_opts, opts)
    _ = remember_adapter(adapter, record, memory_opts)
    :ok
  end

  defp remember_with_adapter(_adapter, _record, _opts), do: :ok

  @spec recall_adapter(module(), Mission.t(), keyword()) :: term()
  defp recall_adapter(adapter, mission, opts) do
    adapter.recall(mission, opts)
  rescue
    error -> {:error, {:memory_adapter_failed, adapter, :recall, error}}
  catch
    kind, reason -> {:error, {:memory_adapter_failed, adapter, :recall, {kind, reason}}}
  end

  @spec remember_adapter(module(), term(), keyword()) :: term()
  defp remember_adapter(adapter, record, opts) do
    adapter.remember(record, opts)
  rescue
    error -> {:error, {:memory_adapter_failed, adapter, :remember, error}}
  catch
    kind, reason -> {:error, {:memory_adapter_failed, adapter, :remember, {kind, reason}}}
  end
end
