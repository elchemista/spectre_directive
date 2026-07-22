defmodule SpectreDirective.Invocation do
  @moduledoc """
  A trusted host invocation proposed by an authored step or reasoner.

  The target may be an anonymous function, a module implementing
  `SpectreDirective.Invoker`, or an MFA-style tuple supported by the local
  interpreter. The core engine emits it as data and never calls it directly.
  """

  @type target :: SpectreDirective.Invoker.target()

  @type t :: %__MODULE__{
          target: target(),
          policy: term(),
          metadata: map()
        }

  defstruct [:target, :policy, metadata: %{}]

  @doc "Builds an invocation."
  @spec new(target() | t(), keyword() | map()) :: t()
  def new(target, opts \\ [])

  def new(%__MODULE__{} = invocation, opts) do
    opts = Map.new(opts)

    %{
      invocation
      | policy: Map.get(opts, :policy, invocation.policy),
        metadata: Map.merge(invocation.metadata, Map.new(Map.get(opts, :metadata, %{})))
    }
  end

  def new(target, opts) do
    opts = Map.new(opts)

    %__MODULE__{
      target: target,
      policy: Map.get(opts, :policy),
      metadata: Map.new(Map.get(opts, :metadata, %{}))
    }
  end
end
