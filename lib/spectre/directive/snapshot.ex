defmodule Spectre.Directive.Snapshot do
  @moduledoc """
  Versioned, host-persistable state for one Directive conversation.

  A snapshot contains the complete pure mission loop, including its mission,
  living plan, pending correlated request, working context, causal trace, and
  terminal outcome. It deliberately contains no pid or task reference. The
  `turn_receipts` record visible replies so transport retries with stable turn
  ids can be replayed without advancing the mission twice, including delayed
  duplicates that arrive after a later turn.

  Store implementations should treat snapshots as trusted application data.
  Callback targets may contain modules, MFAs, or local functions, so durable
  stores should prefer stable module/MFA targets and must never deserialize
  untrusted external terms.
  """

  alias SpectreDirective.Loop.State

  @version 1
  @terminal_statuses [:completed, :failed, :cancelled]

  @enforce_keys [:key, :state, :snapshotted_at]
  defstruct version: @version,
            revision: 1,
            key: nil,
            state: nil,
            runtime_opts: [],
            snapshotted_at: nil,
            last_turn_id: nil,
            turn_receipts: %{},
            metadata: %{}

  @type recorded_turn :: %{
          required(:id) => term(),
          required(:input) => term(),
          required(:boundary) => term(),
          required(:reply_text) => String.t(),
          required(:snapshot_revision) => pos_integer(),
          required(:plan_version) => non_neg_integer()
        }

  @type t :: %__MODULE__{
          version: pos_integer(),
          revision: pos_integer(),
          key: term(),
          state: State.t(),
          runtime_opts: keyword(),
          snapshotted_at: DateTime.t(),
          last_turn_id: term(),
          turn_receipts: %{optional(term()) => recorded_turn()},
          metadata: map()
        }

  @typedoc false
  @type unchecked :: %__MODULE__{
          version: term(),
          revision: term(),
          key: term(),
          state: term(),
          runtime_opts: term(),
          snapshotted_at: term(),
          last_turn_id: term(),
          turn_receipts: term(),
          metadata: term()
        }

  @doc "Builds a versioned snapshot from complete pure loop state."
  @spec new(term(), State.t(), keyword()) :: t()
  def new(key, %State{} = state, opts \\ []) when not is_nil(key) and is_list(opts) do
    runtime_opts = Keyword.get(opts, :runtime_opts, [])
    metadata = Keyword.get(opts, :metadata, %{})

    if Keyword.keyword?(runtime_opts) and is_map(metadata) do
      %__MODULE__{
        key: key,
        state: state,
        runtime_opts: runtime_opts,
        snapshotted_at: DateTime.utc_now(),
        metadata: metadata
      }
    else
      raise ArgumentError,
            "snapshot runtime_opts must be a keyword list and metadata must be a map"
    end
  end

  @doc "Refreshes and advances a snapshot at the mission's next durable boundary."
  @spec refresh(t(), State.t()) :: t()
  def refresh(%__MODULE__{} = snapshot, %State{} = state) do
    %{
      snapshot
      | revision: snapshot.revision + 1,
        state: state,
        snapshotted_at: DateTime.utc_now()
    }
  end

  @doc """
  Records the externally visible reply produced for a turn identifier.

  A transport can pass its stable message identifier to Spectre as `:turn_id`.
  If delivery is ambiguous and that same turn is retried, the integration can
  return this recorded reply without consuming the input a second time.
  """
  @spec record_turn(t(), term(), term(), term(), String.t()) :: t()
  def record_turn(%__MODULE__{} = snapshot, turn_id, input, boundary, reply_text)
      when not is_nil(turn_id) and is_binary(reply_text) do
    %{
      snapshot
      | last_turn_id: turn_id,
        turn_receipts:
          Map.put(snapshot.turn_receipts, turn_id, %{
            id: turn_id,
            input: input,
            boundary: boundary,
            reply_text: reply_text,
            snapshot_revision: snapshot.revision,
            plan_version: snapshot.state.plan.version
          })
    }
  end

  def record_turn(%__MODULE__{} = snapshot, nil, _input, _boundary, reply_text)
      when is_binary(reply_text),
      do: snapshot

  @doc false
  @spec replay(t(), term(), term()) :: {:ok, recorded_turn()} | :miss | {:error, term()}
  def replay(%__MODULE__{}, nil, _input), do: :miss

  def replay(%__MODULE__{turn_receipts: receipts}, turn_id, input) do
    case Map.fetch(receipts, turn_id) do
      {:ok, %{input: ^input} = turn} -> {:ok, turn}
      {:ok, _turn} -> {:error, {:directive_turn_id_reused, turn_id}}
      :error -> :miss
    end
  end

  @doc "Returns true while the stored mission can still consume user input."
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{state: %State{status: status}}),
    do: status not in @terminal_statuses

  @doc false
  @spec validate(unchecked(), term()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = snapshot, expected_key \\ :any) do
    with :ok <- validate_version(snapshot),
         :ok <- validate_revision(snapshot),
         :ok <- validate_key(snapshot, expected_key),
         :ok <- validate_state(snapshot),
         :ok <- validate_runtime_opts(snapshot),
         :ok <- validate_timestamp(snapshot),
         :ok <- validate_receipts(snapshot),
         :ok <- validate_last_turn_id(snapshot) do
      validate_metadata(snapshot)
    end
  end

  @spec validate_version(unchecked()) :: :ok | {:error, term()}
  defp validate_version(%__MODULE__{version: @version}), do: :ok

  defp validate_version(%__MODULE__{version: version}),
    do: {:error, {:unsupported_snapshot_version, version}}

  @spec validate_revision(unchecked()) :: :ok | {:error, term()}
  defp validate_revision(%__MODULE__{revision: revision})
       when is_integer(revision) and revision >= 1,
       do: :ok

  defp validate_revision(%__MODULE__{revision: revision}),
    do: {:error, {:invalid_snapshot_revision, revision}}

  @spec validate_key(unchecked(), term()) :: :ok | {:error, term()}
  defp validate_key(%__MODULE__{key: nil}, _expected_key), do: {:error, :snapshot_key_required}
  defp validate_key(%__MODULE__{}, :any), do: :ok
  defp validate_key(%__MODULE__{key: key}, key), do: :ok

  defp validate_key(%__MODULE__{key: actual}, expected),
    do: {:error, {:snapshot_key_mismatch, expected, actual}}

  @spec validate_state(unchecked()) :: :ok | {:error, term()}
  defp validate_state(%__MODULE__{state: %State{}}), do: :ok

  defp validate_state(%__MODULE__{state: state}),
    do: {:error, {:invalid_snapshot_state, shape(state)}}

  @spec validate_runtime_opts(unchecked()) :: :ok | {:error, term()}
  defp validate_runtime_opts(%__MODULE__{runtime_opts: opts}) do
    if Keyword.keyword?(opts),
      do: :ok,
      else: {:error, {:invalid_snapshot_runtime_options, shape(opts)}}
  end

  @spec validate_timestamp(unchecked()) :: :ok | {:error, term()}
  defp validate_timestamp(%__MODULE__{snapshotted_at: %DateTime{}}), do: :ok

  defp validate_timestamp(%__MODULE__{snapshotted_at: timestamp}),
    do: {:error, {:invalid_snapshot_timestamp, shape(timestamp)}}

  @spec validate_receipts(unchecked()) :: :ok | {:error, term()}
  defp validate_receipts(%__MODULE__{turn_receipts: receipts}) do
    if valid_turn_receipts?(receipts),
      do: :ok,
      else: {:error, {:invalid_snapshot_turn_receipts, shape(receipts)}}
  end

  @spec validate_last_turn_id(unchecked()) :: :ok | {:error, term()}
  defp validate_last_turn_id(%__MODULE__{last_turn_id: turn_id, turn_receipts: receipts}) do
    if valid_last_turn_id?(turn_id, receipts),
      do: :ok,
      else: {:error, {:invalid_snapshot_last_turn_id, turn_id}}
  end

  @spec validate_metadata(unchecked()) :: :ok | {:error, term()}
  defp validate_metadata(%__MODULE__{metadata: metadata}) when is_map(metadata), do: :ok

  defp validate_metadata(%__MODULE__{metadata: metadata}),
    do: {:error, {:invalid_snapshot_metadata, shape(metadata)}}

  @spec shape(term()) :: atom() | {:struct, module()}
  defp shape(value) when is_atom(value), do: :atom
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_list(value), do: :list
  defp shape(%{__struct__: module}), do: {:struct, module}
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other

  @spec valid_turn_receipts?(term()) :: boolean()
  defp valid_turn_receipts?(receipts) when is_map(receipts) do
    Enum.all?(receipts, fn
      {id,
       %{
         id: id,
         input: _input,
         boundary: _boundary,
         reply_text: reply_text,
         snapshot_revision: snapshot_revision,
         plan_version: plan_version
       }} ->
        not is_nil(id) and is_binary(reply_text) and is_integer(snapshot_revision) and
          snapshot_revision > 0 and is_integer(plan_version) and plan_version >= 0

      {_id, _receipt} ->
        false
    end)
  end

  defp valid_turn_receipts?(_receipts), do: false

  @spec valid_last_turn_id?(term(), map()) :: boolean()
  defp valid_last_turn_id?(nil, receipts), do: map_size(receipts) == 0
  defp valid_last_turn_id?(turn_id, receipts), do: Map.has_key?(receipts, turn_id)
end
