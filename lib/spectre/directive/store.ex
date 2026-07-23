defmodule Spectre.Directive.Store do
  @moduledoc """
  Host-owned persistence boundary for Directive mission snapshots.

  Directive never selects a database or persistence format. Applications pass
  a behaviour module, optionally paired with fixed options:

      defmodule MyApp.DirectiveStore do
        @behaviour Spectre.Directive.Store

        @impl true
        def load(key, opts), do: MyApp.Database.load_directive(key, opts)

        @impl true
        def snapshot(key, snapshot, opts) do
          MyApp.Database.put_directive(key, snapshot, opts)
        end
      end

  `load/2` returns `{:ok, nil}` when no mission exists for the key. Terminal
  snapshots may be retained for audit; the Spectre integration treats them as
  inactive.

  `Snapshot.version` is the storage schema version. `Snapshot.revision` starts
  at one and advances at every durable user boundary. A production Store
  should atomically reject a write when the stored mission has neither the
  immediately preceding revision nor the exact same snapshot. That makes an
  identical retry idempotent and prevents two concurrent turns from silently
  overwriting one another. Reusing a key for a new mission is safe only after
  the prior snapshot is terminal and is a Store-owned policy.

  `Snapshot.turn_receipts` are application-trusted delivery receipts. When a
  host supplies stable external message ids as Spectre's `:turn_id`, the Agent
  integration can replay a recorded reply after an ambiguous or delayed
  delivery. They do not replace the Store's revision check and cannot make
  external invocation side effects transactional with the snapshot write.

  Stores own serialization, transactions, and cross-node concurrency. A
  `Spectre.Session` serializes calls only inside its own process; it does not
  replace the Store's distributed concurrency check.
  """

  alias Spectre.Directive.Snapshot

  @type key :: term()
  @type target :: module() | {module(), keyword()}

  @callback load(key(), keyword()) ::
              {:ok, Snapshot.t() | nil} | {:error, term()}

  @callback snapshot(key(), Snapshot.t(), keyword()) :: :ok | {:error, term()}

  @doc "Loads and validates a snapshot through a configured Store target."
  @spec load(target(), key(), keyword()) :: {:ok, Snapshot.t() | nil} | {:error, term()}
  def load(target, key, opts \\ [])

  def load(target, key, opts) when is_list(opts) do
    with {:ok, module, callback_opts} <- normalize_target(target, opts),
         {:ok, reply} <- invoke(module, :load, [key, callback_opts]) do
      normalize_load(reply, key)
    end
  end

  def load(_target, _key, opts), do: {:error, {:invalid_store_options, shape(opts)}}

  @doc "Validates and persists a complete mission snapshot through a Store target."
  @spec snapshot(target(), key(), Snapshot.t(), keyword()) :: :ok | {:error, term()}
  def snapshot(target, key, snapshot, opts \\ [])

  def snapshot(target, key, %Snapshot{} = snapshot, opts) when is_list(opts) do
    with :ok <- Snapshot.validate(snapshot, key),
         {:ok, module, callback_opts} <- normalize_target(target, opts),
         {:ok, reply} <- invoke(module, :snapshot, [key, snapshot, callback_opts]) do
      normalize_snapshot(reply)
    end
  end

  def snapshot(_target, _key, snapshot, _opts),
    do: {:error, {:invalid_directive_snapshot, shape(snapshot)}}

  @doc false
  @spec validate_target(target()) :: :ok | {:error, term()}
  def validate_target(target) do
    case normalize_target(target, []) do
      {:ok, _module, _opts} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec normalize_target(term(), keyword()) ::
          {:ok, module(), keyword()} | {:error, term()}
  defp normalize_target({module, target_opts}, opts)
       when is_atom(module) and not is_nil(module) and is_list(target_opts) do
    if Keyword.keyword?(target_opts) and Keyword.keyword?(opts) do
      available(module, Keyword.merge(target_opts, opts))
    else
      {:error, {:invalid_directive_store, shape({module, target_opts})}}
    end
  end

  defp normalize_target(module, opts) when is_atom(module) and not is_nil(module) do
    if Keyword.keyword?(opts),
      do: available(module, opts),
      else: {:error, {:invalid_store_options, shape(opts)}}
  end

  defp normalize_target(target, _opts),
    do: {:error, {:invalid_directive_store, shape(target)}}

  @spec available(module(), keyword()) :: {:ok, module(), keyword()} | {:error, term()}
  defp available(module, opts) do
    if Code.ensure_loaded?(module) and function_exported?(module, :load, 2) and
         function_exported?(module, :snapshot, 3) do
      {:ok, module, opts}
    else
      {:error, {:undefined_directive_store, module}}
    end
  end

  @spec invoke(module(), atom(), list()) :: {:ok, term()} | {:error, term()}
  defp invoke(module, function, args) do
    {:ok, apply(module, function, args)}
  rescue
    exception -> {:error, {:directive_store_exception, module, function, exception.__struct__}}
  catch
    kind, reason -> {:error, {:directive_store_failure, module, function, kind, reason}}
  end

  @spec normalize_load(term(), key()) :: {:ok, Snapshot.t() | nil} | {:error, term()}
  defp normalize_load({:ok, nil}, _key), do: {:ok, nil}

  defp normalize_load({:ok, %Snapshot{} = snapshot}, key) do
    with :ok <- Snapshot.validate(snapshot, key), do: {:ok, snapshot}
  end

  defp normalize_load({:error, _reason} = error, _key), do: error

  defp normalize_load(reply, _key),
    do: {:error, {:invalid_directive_store_load_reply, shape(reply)}}

  @spec normalize_snapshot(term()) :: :ok | {:error, term()}
  defp normalize_snapshot(:ok), do: :ok
  defp normalize_snapshot({:error, _reason} = error), do: error

  defp normalize_snapshot(reply),
    do: {:error, {:invalid_directive_store_snapshot_reply, shape(reply)}}

  @spec shape(term()) :: atom() | {:struct, module()}
  defp shape(value) when is_atom(value), do: :atom
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_list(value), do: :list
  defp shape(%{__struct__: module}), do: {:struct, module}
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other
end
