defmodule SpectreDirective.Safe do
  @moduledoc """
  Runtime boundary helpers that turn exceptions, throws, and exits into errors.

  Directive still lets pure internal helpers stay simple. Calls that cross into
  adapters, ports, GenServers, or user-provided job implementations should pass
  through this module so one bad runtime does not crash the manager or caller.
  """

  @typedoc "A normalized crash reason captured at a runtime boundary."
  @type crash_reason ::
          {:exception, Exception.t(), Exception.stacktrace()}
          | {:exit, term()}
          | {:throw, term()}
          | {atom(), term()}

  @doc """
  Runs `fun` and returns either `{:ok, value}` or `{:error, reason}`.
  """
  @spec call((-> term())) :: {:ok, term()} | {:error, crash_reason()}
  def call(fun) when is_function(fun, 0) do
    {:ok, fun.()}
  rescue
    error ->
      {:error, {:exception, error, __STACKTRACE__}}
  catch
    :exit, reason ->
      {:error, {:exit, reason}}

    :throw, reason ->
      {:error, {:throw, reason}}

    kind, reason ->
      {:error, {kind, reason}}
  end

  @doc """
  Runs `fun` and preserves existing `:ok`, `{:ok, value}`, or `{:error, reason}` results.

  Any other returned value is treated as a successful value.
  """
  @spec result((-> term())) :: :ok | {:ok, term()} | {:error, term()}
  def result(fun) when is_function(fun, 0) do
    case call(fun) do
      {:ok, :ok} -> :ok
      {:ok, {:ok, value}} -> {:ok, value}
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Runs a side effect and always returns `:ok`, logging failure into the returned value.
  """
  @spec effect((-> term())) :: :ok | {:error, term()}
  def effect(fun) when is_function(fun, 0) do
    case call(fun) do
      {:ok, _value} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
