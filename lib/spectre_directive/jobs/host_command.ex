defmodule SpectreDirective.Jobs.HostCommand do
  @moduledoc """
  Direct command execution on the current host.

  Host execution is gated by `:allow_host_execution` in the job, call context,
  or application config.
  """

  @type t :: %__MODULE__{
          command: binary() | nil,
          cwd: binary() | nil,
          env: map(),
          timeout_ms: pos_integer(),
          allow_host_execution: boolean(),
          metadata: map()
        }

  defstruct command: nil,
            cwd: nil,
            env: %{},
            timeout_ms: 60_000,
            allow_host_execution: false,
            metadata: %{}
end
