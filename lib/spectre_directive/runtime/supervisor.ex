defmodule SpectreDirective.Runtime.Supervisor do
  @moduledoc "Optional supervision tree for locally executed mission loops."

  use Supervisor

  @registry SpectreDirective.Registry
  @mission_supervisor SpectreDirective.MissionSupervisor
  @task_supervisor SpectreDirective.TaskSupervisor

  @doc "Starts the Registry, mission supervisor, and callback task supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Starts the runtime lazily when the host did not add it to a supervision tree."
  @spec ensure_started(keyword()) :: :ok | {:error, term()}
  def ensure_started(opts \\ []) do
    case Process.whereis(@mission_supervisor) do
      pid when is_pid(pid) -> :ok
      nil -> start_runtime(opts)
    end
  end

  @doc false
  @spec init(keyword()) :: {:ok, {Supervisor.sup_flags(), [Supervisor.child_spec()]}} | :ignore
  @impl Supervisor
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {Task.Supervisor, name: @task_supervisor},
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
