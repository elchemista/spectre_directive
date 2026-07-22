defmodule SpectreDirective.Outcome do
  @moduledoc "A terminal mission result."

  @type status :: :completed | :failed | :cancelled

  @type t :: %__MODULE__{
          mission_id: binary(),
          status: status(),
          result: term(),
          reason: term(),
          completion_result: term(),
          completed_at: DateTime.t(),
          metadata: map()
        }

  defstruct [
    :mission_id,
    :status,
    :result,
    :reason,
    :completion_result,
    :completed_at,
    metadata: %{}
  ]

  @doc "Builds a terminal outcome."
  @spec new(binary(), status(), keyword()) :: t()
  def new(mission_id, status, opts \\ []) do
    %__MODULE__{
      mission_id: mission_id,
      status: status,
      result: Keyword.get(opts, :result),
      reason: Keyword.get(opts, :reason),
      completion_result: Keyword.get(opts, :completion_result),
      completed_at: Keyword.get(opts, :completed_at) || DateTime.utc_now(),
      metadata: Map.new(Keyword.get(opts, :metadata, %{}))
    }
  end
end
