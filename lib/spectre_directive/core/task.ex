defmodule SpectreDirective.Task do
  @moduledoc """
  Runtime record for one tracked Directive task.

  The `job` field contains executable intent. The task itself is lifecycle state.
  """

  @type status :: :queued | :running | :succeeded | :failed | :cancelled

  @type t :: %__MODULE__{
          id: binary(),
          parent_id: binary() | nil,
          title: binary() | nil,
          job: term(),
          status: status(),
          progress: map(),
          result: term(),
          error: term(),
          last_event: atom() | nil,
          last_message: term(),
          last_event_at: DateTime.t() | nil,
          session_id: binary() | nil,
          attempt: non_neg_integer(),
          events: [SpectreDirective.Event.t()],
          pid: pid() | nil,
          ref: reference() | nil,
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil
        }

  defstruct [
    :id,
    :parent_id,
    :title,
    :job,
    :result,
    :error,
    :last_event,
    :last_message,
    :last_event_at,
    :session_id,
    :pid,
    :ref,
    :started_at,
    :finished_at,
    status: :queued,
    progress: %{},
    attempt: 0,
    events: []
  ]

  @doc """
  Builds a queued task record around executable job intent.
  """
  @spec new(term(), keyword()) :: t()
  def new(job, opts \\ []) do
    %__MODULE__{
      id: Keyword.get(opts, :id) || unique_id("task"),
      parent_id: Keyword.get(opts, :parent_id),
      title: Keyword.get(opts, :title),
      job: job,
      attempt: Keyword.get(opts, :attempt, 0)
    }
  end

  @spec unique_id(binary()) :: binary()
  defp unique_id(prefix) do
    "#{prefix}_#{System.unique_integer([:positive, :monotonic])}"
  end
end
