defimpl SpectreDirective.Job, for: SpectreDirective.Jobs.CodexAgent do
  @moduledoc false

  alias SpectreDirective.Codex.AppServer

  @spec describe(SpectreDirective.Jobs.CodexAgent.t()) :: map()
  def describe(_job) do
    %{
      type: :codex_agent,
      capability: "Run a Codex app-server turn in a workspace.",
      risk: :high,
      required_fields: [:prompt, :cwd],
      expected_output: "Codex turn completion or structured failure",
      isolation_modes: [:agent, :workspace]
    }
  end

  @spec validate(SpectreDirective.Jobs.CodexAgent.t(), map()) :: :ok | {:error, term()}
  def validate(%{prompt: prompt}, _context) when not is_binary(prompt) or prompt == "",
    do: {:error, {:invalid_job, :missing_prompt}}

  def validate(%{cwd: cwd}, _context) when not is_binary(cwd) or cwd == "",
    do: {:error, {:invalid_job, :missing_cwd}}

  def validate(job, _context) do
    cond do
      is_nil(System.find_executable("bash")) ->
        {:error, {:runtime_unavailable, :bash}}

      String.trim(job.command || "") == "" ->
        {:error, {:invalid_job, :missing_codex_command}}

      true ->
        :ok
    end
  end

  @spec isolation(SpectreDirective.Jobs.CodexAgent.t(), map()) :: map()
  def isolation(job, _context),
    do: %{mode: :agent, adapter: :codex, cwd: job.cwd, timeout_ms: job.timeout_ms}

  @spec run(SpectreDirective.Jobs.CodexAgent.t(), map()) :: {:ok, term()} | {:error, term()}
  def run(job, context) do
    with :ok <- validate(job, context) do
      AppServer.run(job, context)
    end
  end

  @spec cancel(SpectreDirective.Jobs.CodexAgent.t(), map()) :: :ok
  def cancel(_job, _context), do: :ok
end
