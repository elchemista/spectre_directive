defmodule SpectreDirective.Manager.State do
  @moduledoc """
  Internal runtime state for `SpectreDirective.Manager`.
  """

  alias SpectreDirective.Task, as: DirectiveTask

  @type t :: %__MODULE__{
          queued: %{optional(binary()) => DirectiveTask.t()},
          running: %{optional(binary()) => DirectiveTask.t()},
          claimed: term(),
          completed: %{optional(binary()) => DirectiveTask.t()},
          retry_attempts: map(),
          agent_totals: map(),
          rate_limits: map() | nil,
          max_concurrent: pos_integer()
        }

  defstruct queued: %{},
            running: %{},
            claimed: MapSet.new(),
            completed: %{},
            retry_attempts: %{},
            agent_totals: %{
              input_tokens: 0,
              output_tokens: 0,
              total_tokens: 0,
              seconds_running: 0
            },
            rate_limits: nil,
            max_concurrent: System.schedulers_online()
end
