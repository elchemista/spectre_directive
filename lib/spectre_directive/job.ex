defprotocol SpectreDirective.Job do
  @moduledoc """
  Protocol implemented by executable Directive job structs.

  Directive's manager tracks task lifecycle. Job implementations own their
  validation, isolation requirements, execution, and cancellation behavior.
  """

  @fallback_to_any true

  @doc """
  Returns LLM-readable metadata about what the job can do.
  """
  @spec describe(t()) :: map()
  def describe(job)

  @doc """
  Validates that a job can run in the supplied context.
  """
  @spec validate(t(), map()) :: :ok | {:error, term()}
  def validate(job, context)

  @doc """
  Returns the concrete isolation request for a job.
  """
  @spec isolation(t(), map()) :: map()
  def isolation(job, context)

  @doc """
  Executes the job and reports progress through the context emitter.
  """
  @spec run(t(), map()) :: {:ok, term()} | {:error, term()}
  def run(job, context)

  @doc """
  Cancels active job work when the implementation supports cancellation.
  """
  @spec cancel(t(), map()) :: :ok | {:error, term()}
  def cancel(job, context)
end
