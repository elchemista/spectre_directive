defmodule SpectreDirective.KineticAdapter do
  @moduledoc """
  Optional bridge to SpectreKinetic.

  This module never creates a compile-time dependency. It uses `Code.ensure_loaded?`
  and `apply/3`, so Directive works without Kinetic installed.
  """

  alias SpectreDirective.AL

  @doc """
  Resolves input through optional SpectreKinetic when configured.

  If no `:kinetic` target is passed, Directive's built-in AL resolver is used.
  """
  @spec resolve(term(), keyword()) :: {:ok, term()} | {:error, term()}
  def resolve(input, opts \\ []) do
    target = Keyword.get(opts, :kinetic)

    cond do
      is_nil(target) ->
        AL.resolve(input, opts)

      !Code.ensure_loaded?(SpectreKinetic) ->
        {:error, {:optional_runtime_unavailable, :spectre_kinetic}}

      is_binary(input) ->
        plan_with_kinetic(target, input, opts)

      true ->
        AL.resolve(input, opts)
    end
  end

  @spec plan_with_kinetic(term(), binary(), keyword()) :: {:ok, term()} | {:error, term()}
  defp plan_with_kinetic(target, input, opts) do
    plan_opts = Keyword.get(opts, :kinetic_opts, [])

    # Keep this optional integration free of a compile-time dependency.
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    case apply(SpectreKinetic, :plan, [target, input, plan_opts]) do
      {:ok, action} ->
        action_to_job(action, opts)

      {:error, reason} ->
        {:error, {:kinetic_plan_failed, reason}}
    end
  rescue
    error -> {:error, {:kinetic_plan_failed, error}}
  end

  @spec action_to_job(term(), keyword()) :: {:ok, term()} | {:error, term()}
  defp action_to_job(%{al: al, status: :ok}, opts) when is_binary(al), do: AL.resolve(al, opts)

  defp action_to_job(%{status: status} = action, _opts),
    do: {:error, {:kinetic_action_not_executable, status, action}}

  defp action_to_job(action, _opts), do: {:error, {:invalid_kinetic_action, action}}
end
