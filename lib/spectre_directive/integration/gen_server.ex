defmodule SpectreDirective.Integration.GenServer do
  @moduledoc """
  Composable bridge for a GenServer that owns application state while each
  directive remains isolated in its supervised mission process.
  """

  @doc "Starts an authored directive and subscribes the resolved server process."
  @spec start(module(), GenServer.server(), binary() | atom() | nil, keyword()) ::
          {:ok, pid()} | {:error, term()}
  def start(owner, server, name, opts \\ [])
      when is_atom(owner) and is_list(opts) do
    with {:ok, subscriber} <- server_pid(server) do
      subscribers = [subscriber | List.wrap(Keyword.get(opts, :subscribers, []))] |> Enum.uniq()

      opts =
        opts
        |> Keyword.put(:directive, name)
        |> Keyword.put(:subscribers, subscribers)

      SpectreDirective.start_directive(owner, opts)
    end
  end

  @doc "Dispatches a directive event to the host module's overridable callback."
  @spec handle_info(module(), term(), term()) :: term()
  def handle_info(
        owner,
        {:spectre_directive, mission_id, event, payload},
        state
      )
      when is_atom(owner) do
    owner.handle_directive({event, mission_id, payload}, state)
  end

  def handle_info(_owner, _message, state), do: {:noreply, state}

  @spec server_pid(GenServer.server()) :: {:ok, pid()} | {:error, term()}
  defp server_pid(server) when is_pid(server), do: live_pid(server)

  defp server_pid(server) when is_atom(server) do
    server |> Process.whereis() |> resolved_pid(server)
  end

  defp server_pid({:global, name} = server) do
    name |> :global.whereis_name() |> resolved_pid(server)
  end

  defp server_pid({:via, module, name} = server) when is_atom(module) do
    module.whereis_name(name) |> resolved_pid(server)
  rescue
    error -> {:error, {:invalid_gen_server, server, error}}
  end

  defp server_pid(server), do: {:error, {:invalid_gen_server, server}}

  @spec live_pid(pid()) :: {:ok, pid()} | {:error, term()}
  defp live_pid(pid) do
    if Process.alive?(pid), do: {:ok, pid}, else: {:error, {:gen_server_not_alive, pid}}
  end

  @spec resolved_pid(pid() | :undefined | nil, term()) :: {:ok, pid()} | {:error, term()}
  defp resolved_pid(pid, _server) when is_pid(pid), do: live_pid(pid)
  defp resolved_pid(_missing, server), do: {:error, {:gen_server_not_found, server}}
end
