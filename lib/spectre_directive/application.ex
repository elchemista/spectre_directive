defmodule SpectreDirective.Application do
  @moduledoc false

  use Application

  @impl true
  @doc false
  @spec start(Application.start_type(), term()) :: Supervisor.on_start()
  def start(_type, _args) do
    children = [
      SpectreDirective.WorkflowStore,
      {Task.Supervisor, name: SpectreDirective.TaskSupervisor},
      SpectreDirective.Manager
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: SpectreDirective.Supervisor)
  end
end
