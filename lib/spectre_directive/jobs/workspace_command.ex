defmodule SpectreDirective.Jobs.WorkspaceCommand do
  @moduledoc """
  Command execution inside a prepared workspace directory.
  """

  @type t :: %__MODULE__{
          command: binary() | nil,
          cwd: binary() | nil,
          workspace_root: binary() | nil,
          env: map(),
          timeout_ms: pos_integer(),
          metadata: map()
        }

  defstruct command: nil,
            cwd: nil,
            workspace_root: nil,
            env: %{},
            timeout_ms: 60_000,
            metadata: %{}
end
