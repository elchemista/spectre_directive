defmodule SpectreDirective.Trace.Entry do
  @moduledoc """
  A human-readable explanation of what changed and why.

  Trace entries are not generic logs. They are the mission story: started,
  recalled, skipped, paused, corrected, observed, finished. This is the surface
  a human or monitor agent reads to understand why the plan moved.
  """

  alias SpectreDirective.ID

  @type t :: %__MODULE__{
          id: binary(),
          mission_id: binary(),
          type: atom(),
          message: binary(),
          data: term(),
          timestamp: DateTime.t()
        }

  defstruct [:id, :mission_id, :type, :message, :data, :timestamp]

  @doc """
  Builds one trace entry.
  """
  @spec new(binary(), atom(), binary(), term()) :: t()
  def new(mission_id, type, message, data \\ nil) do
    %__MODULE__{
      id: ID.new("trace"),
      mission_id: mission_id,
      type: type,
      message: message,
      data: data,
      timestamp: DateTime.utc_now()
    }
  end
end
