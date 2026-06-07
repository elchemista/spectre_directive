defmodule SpectreDirective.Runtime.Supervisor do
  @moduledoc """
  Optional supervision tree for mission runtime infrastructure.

  Host applications can supervise this module explicitly. Script-style callers
  can also use `SpectreDirective.start_mission/2` directly; the runtime will be
  started lazily when no host supervisor is present.
  """

  use Supervisor

  @registry SpectreDirective.Registry
  @mission_supervisor SpectreDirective.MissionSupervisor
  @supervisor SpectreDirective.Supervisor

  @doc """
  Starts the runtime supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @supervisor))
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) when is_list(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc """
  Ensures the runtime registry and dynamic supervisor are available.
  """
  @spec ensure_started(keyword()) :: :ok | {:error, term()}
  def ensure_started(opts \\ []) when is_list(opts) do
    case Process.whereis(@mission_supervisor) do
      pid when is_pid(pid) -> :ok
      nil -> start_runtime(opts)
    end
  end

  @impl Supervisor
  @spec init(keyword()) :: {:ok, {Supervisor.sup_flags(), [Supervisor.child_spec()]}}
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, strategy: :one_for_one, name: @mission_supervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @spec start_runtime(keyword()) :: :ok | {:error, term()}
  defp start_runtime(opts) do
    case start_link(opts) do
      {:ok, pid} ->
        Process.unlink(pid)
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
