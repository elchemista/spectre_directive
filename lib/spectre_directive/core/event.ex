defmodule SpectreDirective.Event do
  @moduledoc """
  One task lifecycle, output, progress, or adapter event.
  """

  @type t :: %__MODULE__{
          id: binary(),
          task_id: binary(),
          type: atom(),
          payload: term(),
          timestamp: DateTime.t()
        }

  defstruct [:id, :task_id, :type, :payload, :timestamp]

  @doc """
  Builds a timestamped event for a task.
  """
  @spec new(binary(), atom(), term()) :: t()
  def new(task_id, type, payload \\ nil) when is_binary(task_id) and is_atom(type) do
    %__MODULE__{
      id: unique_id("evt"),
      task_id: task_id,
      type: type,
      payload: payload,
      timestamp: DateTime.utc_now()
    }
  end

  @spec unique_id(binary()) :: binary()
  defp unique_id(prefix) do
    "#{prefix}_#{System.unique_integer([:positive, :monotonic])}"
  end
end
