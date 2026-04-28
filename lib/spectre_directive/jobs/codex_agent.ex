defmodule SpectreDirective.Jobs.CodexAgent do
  @moduledoc """
  Codex app-server backed agent job.
  """

  @type t :: %__MODULE__{
          prompt: binary() | nil,
          cwd: binary() | nil,
          model: binary() | nil,
          command: binary(),
          approval_policy: binary() | map(),
          thread_sandbox: binary(),
          sandbox_policy: map(),
          timeout_ms: pos_integer(),
          metadata: map()
        }

  defstruct prompt: nil,
            cwd: nil,
            model: nil,
            command: "codex app-server",
            approval_policy: "never",
            thread_sandbox: "workspace-write",
            sandbox_policy: %{},
            timeout_ms: 3_600_000,
            metadata: %{}
end
