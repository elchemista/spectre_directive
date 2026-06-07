defmodule SpectreDirective.Correction.Catalog do
  @moduledoc """
  Built-in correction and strategy names from the concept.
  """

  @types [
    :continue,
    :skip_step,
    :remove_steps,
    :add_step,
    :replace_step,
    :reorder_steps,
    :narrow_scope,
    :expand_scope,
    :ask_user,
    :wait,
    :retry,
    :delegate,
    :finish_early,
    :abort
  ]

  @strategies [:tactical, :strategic, :scope, :evidence, :cost, :risk, :confidence, :drift]

  @doc """
  Returns built-in correction types.
  """
  @spec types() :: [atom()]
  def types, do: @types

  @doc """
  Returns built-in correction strategy categories.
  """
  @spec strategies() :: [atom()]
  def strategies, do: @strategies
end
