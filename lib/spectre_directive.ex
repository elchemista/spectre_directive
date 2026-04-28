defmodule SpectreDirective do
  @moduledoc """
  AL-first task and multiagent runner with protocol-based jobs.
  """

  alias SpectreDirective.{AL, Job, KineticAdapter, Manager, Presenter}

  @doc """
  Resolves AL, a list of AL lines, or an existing job struct into an executable job.
  """
  @spec resolve(term(), keyword()) :: {:ok, term()} | {:error, term()}
  def resolve(input, opts \\ []) do
    if Keyword.has_key?(opts, :kinetic) do
      KineticAdapter.resolve(input, opts)
    else
      AL.resolve(input, opts)
    end
  end

  @doc """
  Describes a job in LLM-readable terms.
  """
  @spec describe(term()) :: map()
  def describe(job), do: Job.describe(job)

  @doc """
  Submits a job or AL instruction for asynchronous execution.
  """
  @spec submit(term(), keyword()) :: {:ok, SpectreDirective.Task.t()} | {:error, term()}
  def submit(input, opts \\ []) do
    Manager.submit(input, opts)
  end

  @doc """
  Runs a job or AL instruction and waits for terminal state.
  """
  @spec run(term(), keyword()) :: {:ok, term()} | {:error, term()}
  def run(input, opts \\ []) do
    timeout = Keyword.get(opts, :await_timeout_ms, Keyword.get(opts, :timeout_ms, 60_000) + 1_000)

    with {:ok, task} <- submit(input, opts),
         {:ok, finished} <- await(task.id, timeout) do
      case finished.status do
        :succeeded -> {:ok, finished.result}
        :failed -> {:error, finished.error}
        :cancelled -> {:error, :cancelled}
      end
    end
  end

  @doc """
  Builds and submits a workflow job from AL lines or job structs.
  """
  @spec workflow(list(), keyword()) :: {:ok, SpectreDirective.Task.t()} | {:error, term()}
  def workflow(steps, opts \\ []) when is_list(steps) do
    opts = Keyword.put_new(opts, :mode, Keyword.get(opts, :workflow_mode, :sequential))
    submit(steps, opts)
  end

  @doc """
  Returns current task status.
  """
  @spec status(binary()) :: {:ok, SpectreDirective.Task.t()} | {:error, term()}
  defdelegate status(task_id), to: Manager

  @doc """
  Returns current task status as LLM-readable text.
  """
  @spec status_text(binary()) :: {:ok, binary()} | {:error, binary()}
  def status_text(task_id) do
    case status(task_id) do
      {:ok, task} -> {:ok, Presenter.task(task)}
      {:error, reason} -> {:error, Presenter.error(reason)}
    end
  end

  @doc """
  Returns task events in chronological order.
  """
  @spec events(binary()) :: {:ok, [SpectreDirective.Event.t()]} | {:error, term()}
  defdelegate events(task_id), to: Manager

  @doc """
  Returns task events as LLM-readable text.
  """
  @spec events_text(binary()) :: {:ok, binary()} | {:error, binary()}
  def events_text(task_id) do
    case events(task_id) do
      {:ok, events} -> {:ok, Presenter.events(events)}
      {:error, reason} -> {:error, Presenter.error(reason)}
    end
  end

  @doc """
  Cancels a queued or running task.
  """
  @spec cancel(binary()) :: :ok | {:error, term()}
  defdelegate cancel(task_id), to: Manager

  @doc """
  Returns a manager snapshot with queued/running/completed/retry state.
  """
  @spec snapshot() :: map()
  defdelegate snapshot, to: Manager

  @doc """
  Returns a manager snapshot as LLM-readable text.
  """
  @spec snapshot_text() :: binary()
  def snapshot_text do
    snapshot()
    |> Presenter.snapshot()
  end

  @doc """
  Explains a task error in agent-readable text.
  """
  @spec error_text(term()) :: binary()
  def error_text(reason), do: Presenter.error(reason)

  @doc """
  Waits until a task reaches a terminal state.
  """
  @spec await(binary(), timeout()) :: {:ok, SpectreDirective.Task.t()} | {:error, term()}
  def await(task_id, timeout \\ 60_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await(task_id, deadline)
  end

  defp do_await(task_id, deadline) do
    case status(task_id) do
      {:ok, %{status: status} = task} when status in [:succeeded, :failed, :cancelled] ->
        {:ok, task}

      {:ok, _task} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(20)
          do_await(task_id, deadline)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
