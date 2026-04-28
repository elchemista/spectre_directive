defmodule SpectreDirective.Jobs.Agent do
  @moduledoc """
  Generic future-agent job.

  The default implementation delegates to a supplied module implementing
  `run/2`. This keeps Directive extensible without knowing every agent runtime.
  """

  @type t :: %__MODULE__{
          prompt: binary() | nil,
          model: binary() | nil,
          role: binary() | nil,
          adapter: module() | nil,
          timeout_ms: pos_integer(),
          metadata: map()
        }

  defstruct prompt: nil,
            model: nil,
            role: nil,
            adapter: nil,
            timeout_ms: 300_000,
            metadata: %{}
end
