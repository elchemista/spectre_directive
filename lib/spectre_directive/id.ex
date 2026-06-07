defmodule SpectreDirective.ID do
  @moduledoc false

  @doc false
  @spec new(binary()) :: binary()
  def new(prefix) when is_binary(prefix) do
    "#{prefix}_#{System.unique_integer([:positive, :monotonic])}"
  end
end
