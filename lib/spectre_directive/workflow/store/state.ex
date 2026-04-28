defmodule SpectreDirective.WorkflowStore.State do
  @moduledoc """
  Cached workflow payload and file fingerprint for `SpectreDirective.WorkflowStore`.
  """

  alias SpectreDirective.Workflow

  @type t :: %__MODULE__{
          path: Path.t() | nil,
          stamp: term(),
          workflow: Workflow.loaded()
        }

  defstruct [:path, :stamp, :workflow]
end
