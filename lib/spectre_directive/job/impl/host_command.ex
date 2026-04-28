defimpl SpectreDirective.Job, for: SpectreDirective.Jobs.HostCommand do
  @moduledoc false

  alias SpectreDirective.Command

  @spec describe(SpectreDirective.Jobs.HostCommand.t()) :: map()
  def describe(_job) do
    %{
      type: :host_command,
      capability: "Run a shell command directly on the current host.",
      risk: :high,
      required_fields: [:command],
      expected_output: "exit status and captured output",
      isolation_modes: [:host]
    }
  end

  @spec validate(SpectreDirective.Jobs.HostCommand.t(), map()) ::
          :ok | {:error, {:invalid_job, :missing_command} | {:host_execution_not_allowed, map()}}
  def validate(%{command: command}, _context) when not is_binary(command) or command == "",
    do: {:error, {:invalid_job, :missing_command}}

  def validate(job, context) do
    if allowed?(job, context),
      do: :ok,
      else: {:error, {:host_execution_not_allowed, isolation(job, context)}}
  end

  @spec isolation(SpectreDirective.Jobs.HostCommand.t(), map()) :: map()
  def isolation(job, _context), do: %{mode: :host, cwd: job.cwd, timeout_ms: job.timeout_ms}

  @spec run(SpectreDirective.Jobs.HostCommand.t(), map()) ::
          {:ok, Command.result()} | {:error, term()}
  def run(job, context) do
    with :ok <- validate(job, context) do
      Command.run(job.command,
        cwd: job.cwd,
        env: job.env,
        timeout_ms: job.timeout_ms,
        emit: Map.get(context, :emit)
      )
    end
  end

  @spec cancel(SpectreDirective.Jobs.HostCommand.t(), map()) :: :ok
  def cancel(_job, _context), do: :ok

  @spec allowed?(SpectreDirective.Jobs.HostCommand.t(), map()) :: boolean()
  defp allowed?(job, context) do
    job.allow_host_execution == true or
      Map.get(context, :allow_host_execution) == true or
      Application.get_env(:spectre_directive, :allow_host_execution, false) == true
  end
end
