defmodule SpectreDirective.CapabilitySnapshot do
  @moduledoc """
  Capability inventory captured for one mission turn.
  """

  alias SpectreDirective.Capability

  @type t :: %__MODULE__{
          capabilities: [Capability.t()],
          unavailable: [Capability.t()],
          risky: [Capability.t()],
          captured_at: DateTime.t()
        }

  defstruct capabilities: [], unavailable: [], risky: [], captured_at: nil

  @doc """
  Builds a point-in-time capability inventory.
  """
  @spec new([Capability.t() | map()]) :: t()
  def new(capabilities) do
    capabilities = Enum.map(capabilities, &normalize/1)

    %__MODULE__{
      capabilities: Enum.filter(capabilities, & &1.available?),
      unavailable: Enum.reject(capabilities, & &1.available?),
      risky: Enum.filter(capabilities, &(&1.risk in [:high, :critical] or &1.requires_approval?)),
      captured_at: DateTime.utc_now()
    }
  end

  @doc """
  Finds an available capability by name.
  """
  @spec find(t(), atom() | binary() | nil) :: Capability.t() | nil
  def find(_snapshot, nil), do: nil

  def find(%__MODULE__{} = snapshot, name) do
    Enum.find(snapshot.capabilities, &(to_string(&1.name) == to_string(name)))
  end

  @spec normalize(Capability.t() | map() | keyword()) :: Capability.t()
  defp normalize(%Capability{} = capability), do: capability
  defp normalize(attrs), do: Capability.new(attrs)
end
