defmodule SpectreDirective.Jobs.UserCommand do
  @moduledoc """
  Command execution through `sudo -u` for Linux user isolation.
  """

  @type t :: %__MODULE__{
          command: binary() | nil,
          user: binary() | nil,
          group: binary() | nil,
          cwd: binary() | nil,
          env: map(),
          timeout_ms: pos_integer(),
          metadata: map()
        }

  defstruct command: nil,
            user: nil,
            group: nil,
            cwd: nil,
            env: %{},
            timeout_ms: 60_000,
            metadata: %{}
end
