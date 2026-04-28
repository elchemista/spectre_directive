defimpl SpectreDirective.Job, for: SpectreDirective.Jobs.Agent do
  @moduledoc false

  @spec describe(SpectreDirective.Jobs.Agent.t()) :: map()
  def describe(_job) do
    %{
      type: :agent,
      capability: "Run a prompt through a configured agent adapter.",
      risk: :adapter_defined,
      required_fields: [:prompt, :adapter],
      expected_output: "adapter-defined agent result",
      isolation_modes: [:agent]
    }
  end

  @spec validate(SpectreDirective.Jobs.Agent.t(), map()) :: :ok | {:error, term()}
  def validate(%{prompt: prompt}, _context) when not is_binary(prompt) or prompt == "",
    do: {:error, {:invalid_job, :missing_prompt}}

  def validate(%{adapter: nil}, _context), do: {:error, {:runtime_unavailable, :agent_adapter}}

  def validate(%{adapter: adapter}, _context) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :run, 2) do
      :ok
    else
      {:error, {:runtime_unavailable, adapter}}
    end
  end

  @spec isolation(SpectreDirective.Jobs.Agent.t(), map()) :: map()
  def isolation(job, _context),
    do: %{mode: :agent, adapter: job.adapter, model: job.model, timeout_ms: job.timeout_ms}

  @spec run(SpectreDirective.Jobs.Agent.t(), map()) :: {:ok, term()} | {:error, term()}
  def run(job, context) do
    with :ok <- validate(job, context) do
      job.adapter.run(job, context)
    end
  end

  @spec cancel(SpectreDirective.Jobs.Agent.t(), map()) :: :ok | {:error, term()}
  def cancel(job, context) do
    if Code.ensure_loaded?(job.adapter) and function_exported?(job.adapter, :cancel, 2) do
      job.adapter.cancel(job, context)
    else
      :ok
    end
  end
end
