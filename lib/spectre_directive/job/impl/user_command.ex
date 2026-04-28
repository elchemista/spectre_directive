defimpl SpectreDirective.Job, for: SpectreDirective.Jobs.UserCommand do
  @moduledoc false

  alias SpectreDirective.Command

  @spec describe(SpectreDirective.Jobs.UserCommand.t()) :: map()
  def describe(_job) do
    %{
      type: :user_command,
      capability: "Run a command as a configured Linux user or group.",
      risk: :medium,
      required_fields: [:command, :user],
      expected_output: "exit status and captured output",
      isolation_modes: [:linux_user]
    }
  end

  @spec validate(SpectreDirective.Jobs.UserCommand.t(), map()) :: :ok | {:error, term()}
  def validate(%{command: command}, _context) when not is_binary(command) or command == "",
    do: {:error, {:invalid_job, :missing_command}}

  def validate(%{user: user}, _context) when not is_binary(user) or user == "",
    do: {:error, {:invalid_job, :missing_user}}

  def validate(_job, _context) do
    case System.find_executable("sudo") do
      nil -> {:error, {:runtime_unavailable, :sudo}}
      _ -> :ok
    end
  end

  @spec isolation(SpectreDirective.Jobs.UserCommand.t(), map()) :: map()
  def isolation(job, _context) do
    %{
      mode: :linux_user,
      user: job.user,
      group: job.group,
      cwd: job.cwd,
      timeout_ms: job.timeout_ms
    }
  end

  @spec run(SpectreDirective.Jobs.UserCommand.t(), map()) ::
          {:ok, Command.result()} | {:error, term()}
  def run(job, context) do
    with :ok <- validate(job, context) do
      Command.run(build_command(job),
        cwd: job.cwd,
        env: job.env,
        timeout_ms: job.timeout_ms,
        emit: Map.get(context, :emit)
      )
    end
  end

  @spec cancel(SpectreDirective.Jobs.UserCommand.t(), map()) :: :ok
  def cancel(_job, _context), do: :ok

  @spec build_command(SpectreDirective.Jobs.UserCommand.t()) :: binary()
  defp build_command(job) do
    job
    |> sudo_args()
    |> Enum.map_join(" ", &shell_escape/1)
    |> Kernel.<>(" -- " <> job.command)
  end

  @spec sudo_args(SpectreDirective.Jobs.UserCommand.t()) :: [binary()]
  defp sudo_args(%{group: group, user: user}) when is_binary(group) and group != "",
    do: ["sudo", "-n", "-u", user, "-g", group]

  defp sudo_args(%{user: user}), do: ["sudo", "-n", "-u", user]

  @spec shell_escape(term()) :: binary()
  defp shell_escape(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end
end
