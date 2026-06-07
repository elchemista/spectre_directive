defmodule SpectreDirective.Context do
  @moduledoc """
  Mission context that tells the directive what matters.
  """

  @type t :: %__MODULE__{
          text: binary() | nil,
          audience: binary() | nil,
          constraints: [term()],
          preferences: map(),
          metadata: map()
        }

  defstruct text: nil, audience: nil, constraints: [], preferences: %{}, metadata: %{}
end
