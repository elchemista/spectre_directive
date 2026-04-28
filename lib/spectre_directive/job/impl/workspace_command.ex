defimpl SpectreDirective.Job, for: SpectreDirective.Jobs.WorkspaceCommand do
  @moduledoc false

  alias SpectreDirective.{Command, Workspace}

  @spec describe(SpectreDirective.Jobs.WorkspaceCommand.t()) :: map()
  def describe(_job) do
    %{
      type: :workspace_command,
      capability: "Run a shell command in a controlled workspace directory.",
      risk: :medium,
      required_fields: [:command],
      expected_output: "exit status and captured output",
      isolation_modes: [:workspace]
    }
  end

  @spec validate(SpectreDirective.Jobs.WorkspaceCommand.t(), map()) ::
          :ok | {:error, term()}
  def validate(%{command: command}, _context) when not is_binary(command) or command == "",
    do: {:error, {:invalid_job, :missing_command}}

  def validate(job, _context) do
    with {:ok, _cwd} <- Workspace.prepare(job.cwd, root: job.workspace_root) do
      :ok
    end
  end

  @spec isolation(SpectreDirective.Jobs.WorkspaceCommand.t(), map()) :: map()
  def isolation(job, _context),
    do: %{mode: :workspace, cwd: job.cwd, root: job.workspace_root, timeout_ms: job.timeout_ms}

  @spec run(SpectreDirective.Jobs.WorkspaceCommand.t(), map()) ::
          {:ok, Command.result()} | {:error, term()}
  def run(job, context) do
    with :ok <- validate(job, context),
         {:ok, cwd} <- Workspace.prepare(job.cwd, root: job.workspace_root) do
      Command.run(job.command,
        cwd: cwd,
        env: job.env,
        timeout_ms: job.timeout_ms,
        emit: Map.get(context, :emit)
      )
    end
  end

  @spec cancel(SpectreDirective.Jobs.WorkspaceCommand.t(), map()) :: :ok
  def cancel(_job, _context), do: :ok
end
