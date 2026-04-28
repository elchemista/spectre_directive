defmodule SpectreDirective.Jobs.Workflow do
  @moduledoc """
  Workflow job containing child job structs.
  """

  @type mode :: :sequential | :parallel
  @type failure_policy :: :stop | :continue | atom()

  @type t :: %__MODULE__{
          steps: [term()],
          mode: mode(),
          max_concurrency: pos_integer(),
          failure_policy: failure_policy(),
          metadata: map()
        }

  defstruct steps: [],
            mode: :sequential,
            max_concurrency: System.schedulers_online(),
            failure_policy: :stop,
            metadata: %{}
end
