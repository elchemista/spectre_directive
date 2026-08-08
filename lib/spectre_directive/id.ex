defmodule SpectreDirective.ID do
  @moduledoc false

  @doc false
  @spec new(binary()) :: binary()
  def new(prefix) when is_binary(prefix) do
    "#{prefix}_#{Spectre.Identity.uuid7()}"
  end
end
