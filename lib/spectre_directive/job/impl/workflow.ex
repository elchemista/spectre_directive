defimpl SpectreDirective.Job, for: SpectreDirective.Jobs.Workflow do
  @moduledoc false

  alias SpectreDirective.{Job, Safe}

  @spec describe(SpectreDirective.Jobs.Workflow.t()) :: map()
  def describe(_job) do
    %{
      type: :workflow,
      capability: "Run child job structs sequentially or in parallel.",
      risk: :composite,
      required_fields: [:steps],
      expected_output: "ordered child job results",
      isolation_modes: [:composite]
    }
  end

  @spec validate(SpectreDirective.Jobs.Workflow.t(), map()) :: :ok | {:error, term()}
  def validate(%{steps: steps}, _context) when not is_list(steps) or steps == [],
    do: {:error, {:invalid_job, :missing_steps}}

  def validate(%{mode: mode}, _context) when mode not in [:sequential, :parallel],
    do: {:error, {:invalid_job, :invalid_workflow_mode}}

  def validate(job, context) do
    Enum.reduce_while(job.steps, :ok, fn step, :ok ->
      case Job.validate(step, context) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:invalid_child_job, reason}}}
      end
    end)
  end

  @spec isolation(SpectreDirective.Jobs.Workflow.t(), map()) :: map()
  def isolation(job, context) do
    %{mode: :workflow, children: Enum.map(job.steps, &Job.isolation(&1, context))}
  end

  @spec run(SpectreDirective.Jobs.Workflow.t(), map()) :: {:ok, [term()]} | {:error, map()}
  def run(%{mode: :parallel} = job, context) do
    emit = Map.get(context, :emit, fn _type, _payload -> :ok end)
    emit.(:workflow_started, %{mode: :parallel, count: length(job.steps)})

    job.steps
    |> Task.async_stream(
      fn step -> Safe.result(fn -> Job.run(step, context) end) end,
      max_concurrency: max(1, job.max_concurrency || 1),
      timeout: :infinity,
      ordered: true
    )
    |> Enum.map(&normalize_async_result/1)
    |> finish()
  end

  def run(job, context) do
    emit = Map.get(context, :emit, fn _type, _payload -> :ok end)
    emit.(:workflow_started, %{mode: :sequential, count: length(job.steps)})

    job.steps
    |> run_sequential(context, job.failure_policy)
    |> finish()
  end

  @spec cancel(SpectreDirective.Jobs.Workflow.t(), map()) :: :ok
  def cancel(_job, _context), do: :ok

  @spec run_sequential([term()], map(), :stop | atom()) :: [term()]
  defp run_sequential(steps, context, failure_policy) do
    Enum.reduce_while(steps, [], fn step, results ->
      result = Safe.result(fn -> Job.run(step, context) end)
      next_results = results ++ [result]

      if match?({:error, _}, result) and failure_policy == :stop do
        {:halt, next_results}
      else
        {:cont, next_results}
      end
    end)
  end

  @spec normalize_async_result({:ok, term()} | {:exit, term()}) :: term()
  defp normalize_async_result({:ok, result}), do: result
  defp normalize_async_result({:exit, reason}), do: {:error, {:child_exit, reason}}

  @spec finish([term()]) :: {:ok, [term()]} | {:error, %{results: [term()]}}
  defp finish(results) do
    if Enum.any?(results, &match?({:error, _}, &1)) do
      {:error, %{results: results}}
    else
      {:ok, results}
    end
  end
end
