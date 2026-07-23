defmodule SpectreDirective.Integration.SpectreAgent.Conversation do
  @moduledoc false

  alias Spectre.Directive.Presenter
  alias Spectre.Directive.Snapshot
  alias Spectre.Directive.Store
  alias SpectreDirective.Integration.SpectreAgent
  alias SpectreDirective.Loop.State
  alias SpectreDirective.Outcome
  alias SpectreDirective.Request

  @user_input_kinds [:question, :confirmation, :policy]
  @terminal_statuses [:completed, :failed, :cancelled]
  @default_await_timeout 25_000
  @runtime_option_keys [
    :execution,
    :request_handler,
    :policy_handler,
    :policy,
    :request_timeout,
    :runtime_opts
  ]
  @integration_option_keys [
    :owner,
    :store,
    :store_opts,
    :store_namespace,
    :directive_key,
    :presenter,
    :presenter_opts,
    :await_timeout
  ]

  @type boundary :: {:request, Request.t()} | {:outcome, Outcome.t()}
  @type transition :: %{
          required(:boundary) => boundary(),
          required(:reply_text) => String.t(),
          required(:snapshot) => Snapshot.t(),
          required(:metadata) => map()
        }

  @doc false
  @spec start(module(), binary() | atom() | nil, term(), term(), keyword()) ::
          {:ok, transition()} | {:error, term()}
  def start(owner, name, input, spectre_context, opts)
      when is_atom(owner) and is_list(opts) do
    opts = Keyword.put(opts, :owner, owner)
    start_opts = start_options(input, opts)

    snapshot_opts = [
      runtime_opts: runtime_options(start_opts),
      metadata: %{owner: owner, directive: name}
    ]

    with {:ok, key} <- required_key(input, spectre_context, opts),
         {:ok, store} <- store(opts),
         {:ok, store_opts} <- store_opts(opts),
         {:ok, current} <- Store.load(store, key, store_opts),
         :ok <- ensure_inactive(current),
         {:ok, mission} <- SpectreAgent.start(owner, name, start_opts) do
      with_mission(mission, fn ->
        snapshot_started_mission(
          mission,
          key,
          input,
          turn_id(spectre_context),
          store,
          store_opts,
          opts,
          snapshot_opts
        )
      end)
    end
  end

  @spec snapshot_started_mission(
          pid(),
          term(),
          term(),
          term(),
          Store.target(),
          keyword(),
          keyword(),
          keyword()
        ) :: {:ok, transition()} | {:error, term()}
  defp snapshot_started_mission(
         mission,
         key,
         input,
         turn_id,
         store,
         store_opts,
         opts,
         snapshot_opts
       ) do
    with {:ok, boundary} <- SpectreDirective.await_input(mission, await_timeout(opts)),
         {:ok, state} <- SpectreDirective.state(mission) do
      snapshot = Snapshot.new(key, state, snapshot_opts)

      finish(
        store,
        store_opts,
        snapshot,
        boundary,
        input,
        turn_id,
        opts
      )
    end
  end

  @doc false
  @spec resume(term(), term(), keyword()) :: :cont | {:reply, transition()} | {:error, term()}
  def resume(input, spectre_context, opts) when is_list(opts) do
    with {:ok, key} <- optional_key(input, spectre_context, opts) do
      case key do
        nil -> :cont
        key -> resume_key(key, input, spectre_context, opts)
      end
    end
  end

  @spec resume_key(term(), term(), term(), keyword()) ::
          :cont | {:reply, transition()} | {:error, term()}
  defp resume_key(key, input, spectre_context, opts) do
    with {:ok, store} <- store(opts),
         {:ok, store_opts} <- store_opts(opts),
         {:ok, snapshot} <- Store.load(store, key, store_opts) do
      resume_loaded_snapshot(snapshot, input, spectre_context, store, store_opts, opts)
    end
  end

  @spec resume_loaded_snapshot(
          Snapshot.t() | nil,
          term(),
          term(),
          Store.target(),
          keyword(),
          keyword()
        ) :: :cont | {:reply, transition()} | {:error, term()}
  defp resume_loaded_snapshot(nil, _input, _spectre_context, _store, _store_opts, _opts),
    do: :cont

  defp resume_loaded_snapshot(snapshot, input, spectre_context, store, store_opts, opts) do
    case Snapshot.replay(snapshot, turn_id(spectre_context), input) do
      {:ok, recorded_turn} ->
        {:reply, replay_transition(snapshot, recorded_turn)}

      :miss ->
        resume_active(snapshot, input, spectre_context, store, store_opts, opts)

      {:error, _reason} = error ->
        error
    end
  end

  @spec resume_active(
          Snapshot.t(),
          term(),
          term(),
          Store.target(),
          keyword(),
          keyword()
        ) :: :cont | {:reply, transition()} | {:error, term()}
  defp resume_active(snapshot, input, spectre_context, store, store_opts, opts) do
    if Snapshot.active?(snapshot) do
      resume_active_snapshot(snapshot, input, spectre_context, store, store_opts, opts)
    else
      :cont
    end
  end

  @spec resume_active_snapshot(
          Snapshot.t(),
          term(),
          term(),
          Store.target(),
          keyword(),
          keyword()
        ) :: {:reply, transition()} | {:error, term()}
  defp resume_active_snapshot(snapshot, input, spectre_context, store, store_opts, opts) do
    with :ok <- validate_owner(snapshot, opts),
         {:ok, request} <- pending_user_request(snapshot.state),
         {:ok, response} <- response(input, request),
         {:ok, mission} <- restore(snapshot) do
      with_mission(mission, fn ->
        advance_mission(
          mission,
          snapshot,
          response,
          input,
          spectre_context,
          store,
          store_opts,
          opts
        )
      end)
    end
  end

  @spec advance_mission(
          pid(),
          Snapshot.t(),
          term(),
          term(),
          term(),
          Store.target(),
          keyword(),
          keyword()
        ) :: {:reply, transition()} | {:error, term()}
  defp advance_mission(
         mission,
         snapshot,
         response,
         input,
         spectre_context,
         store,
         store_opts,
         opts
       ) do
    with {:ok, boundary} <- SpectreDirective.reply(mission, response, await_timeout(opts)),
         {:ok, state} <- SpectreDirective.state(mission),
         refreshed = Snapshot.refresh(snapshot, state),
         {:ok, transition} <-
           finish(
             store,
             store_opts,
             refreshed,
             boundary,
             input,
             turn_id(spectre_context),
             opts
           ) do
      {:reply, transition}
    end
  end

  @spec restore(Snapshot.t()) :: {:ok, pid()} | {:error, term()}
  defp restore(%Snapshot{} = snapshot) do
    runtime_opts = Keyword.put(snapshot.runtime_opts, :execution, :auto)
    SpectreDirective.start_loop(snapshot.state, runtime_opts)
  end

  @spec finish(
          Store.target(),
          keyword(),
          Snapshot.t(),
          boundary(),
          term(),
          term(),
          keyword()
        ) ::
          {:ok, transition()} | {:error, term()}
  defp finish(store, store_opts, %Snapshot{} = snapshot, boundary, input, turn_id, opts) do
    with {:ok, presenter_opts} <- presenter_opts(opts),
         {:ok, reply_text} <-
           Presenter.call(Keyword.get(opts, :presenter), boundary, presenter_opts),
         snapshot = Snapshot.record_turn(snapshot, turn_id, input, boundary, reply_text),
         :ok <- Store.snapshot(store, snapshot.key, snapshot, store_opts) do
      {:ok, transition(snapshot, boundary, reply_text, false, turn_id: turn_id)}
    end
  end

  @spec replay_transition(Snapshot.t(), Snapshot.recorded_turn()) :: transition()
  defp replay_transition(%Snapshot{} = snapshot, recorded_turn) do
    transition(
      snapshot,
      recorded_turn.boundary,
      recorded_turn.reply_text,
      true,
      turn_id: recorded_turn.id,
      snapshot_revision: recorded_turn.snapshot_revision,
      plan_version: recorded_turn.plan_version
    )
  end

  @spec transition(Snapshot.t(), boundary(), String.t(), boolean(), keyword()) :: transition()
  defp transition(%Snapshot{} = snapshot, boundary, reply_text, replayed?, opts) do
    %{
      boundary: boundary,
      reply_text: reply_text,
      snapshot: snapshot,
      metadata: metadata(snapshot, boundary, replayed?, opts)
    }
  end

  @spec metadata(Snapshot.t(), boundary(), boolean(), keyword()) :: map()
  defp metadata(%Snapshot{} = snapshot, boundary, replayed?, opts) do
    %{
      key: snapshot.key,
      mission_id: snapshot.state.mission.id,
      directive: Map.get(snapshot.metadata, :directive),
      status: boundary_status(boundary),
      plan_version: Keyword.get(opts, :plan_version, snapshot.state.plan.version),
      snapshot_version: snapshot.version,
      snapshot_revision: Keyword.get(opts, :snapshot_revision, snapshot.revision),
      turn_id: Keyword.get(opts, :turn_id, last_turn_id(snapshot)),
      replayed?: replayed?,
      boundary: boundary
    }
  end

  @spec last_turn_id(Snapshot.t()) :: term()
  defp last_turn_id(%Snapshot{last_turn_id: turn_id}), do: turn_id

  @spec boundary_status(boundary()) :: atom()
  defp boundary_status({:request, %Request{}}), do: :waiting
  defp boundary_status({:outcome, %Outcome{status: status}}), do: status

  @spec response(term(), Request.t()) :: {:ok, term()} | {:error, term()}
  defp response(input, %Request{} = request) do
    case structured_response(input) do
      {:ok, response} -> {:ok, response}
      :error -> text_response(input_text(input), request)
    end
  end

  @spec text_response(String.t(), Request.t()) :: {:ok, term()} | {:error, term()}
  defp text_response(text, %Request{kind: :question}), do: {:ok, text}

  defp text_response(text, %Request{kind: :confirmation}) do
    case normalize_choice(text) do
      choice when choice in ["yes", "y", "si", "sì", "ok", "accept", "approve", "approved"] ->
        {:ok, :accept}

      choice when choice in ["no", "n", "reject", "deny", "denied"] ->
        {:ok, {:reject, :rejected_by_user}}

      _other ->
        {:error, {:invalid_directive_confirmation, text}}
    end
  end

  defp text_response(text, %Request{kind: :policy}) do
    case normalize_choice(text) do
      choice when choice in ["yes", "y", "si", "sì", "ok", "allow", "approve", "approved"] ->
        {:ok, :allow}

      choice when choice in ["no", "n", "deny", "denied", "reject"] ->
        {:ok, :deny}

      _other ->
        {:ok, text}
    end
  end

  @spec structured_response(term()) :: {:ok, term()} | :error
  defp structured_response(input) do
    meta = field(input, :meta, %{})

    case fetch(meta, :spectre_directive_response) do
      {:ok, response} -> {:ok, response}
      :error -> fetch(meta, :directive_response)
    end
  end

  @spec pending_user_request(State.t()) :: {:ok, Request.t()} | {:error, term()}
  defp pending_user_request(%State{pending_request: %Request{kind: kind} = request})
       when kind in @user_input_kinds,
       do: {:ok, request}

  defp pending_user_request(%State{pending_request: %Request{kind: kind}}),
    do: {:error, {:snapshot_not_at_user_boundary, kind}}

  defp pending_user_request(%State{status: status}) when status in @terminal_statuses,
    do: {:error, :mission_terminal}

  defp pending_user_request(%State{}), do: {:error, :snapshot_not_at_user_boundary}

  @spec ensure_inactive(Snapshot.t() | nil) :: :ok | {:error, term()}
  defp ensure_inactive(nil), do: :ok

  defp ensure_inactive(%Snapshot{} = snapshot) do
    if Snapshot.active?(snapshot),
      do: {:error, {:directive_already_active, snapshot.state.mission.id}},
      else: :ok
  end

  @spec validate_owner(Snapshot.t(), keyword()) :: :ok | {:error, term()}
  defp validate_owner(%Snapshot{metadata: metadata}, opts) do
    expected = Keyword.get(opts, :owner)

    case Map.get(metadata, :owner) do
      owner when owner in [nil, expected] -> :ok
      owner -> {:error, {:directive_snapshot_owner_mismatch, expected, owner}}
    end
  end

  @spec store(keyword()) :: {:ok, Store.target()} | {:error, term()}
  defp store(opts) do
    case Keyword.get(opts, :store) do
      nil ->
        {:error, :directive_store_required}

      target ->
        with :ok <- Store.validate_target(target), do: {:ok, target}
    end
  end

  @spec store_opts(keyword()) :: {:ok, keyword()} | {:error, term()}
  defp store_opts(opts) do
    callback_opts = Keyword.get(opts, :store_opts, [])

    if Keyword.keyword?(callback_opts) do
      {:ok, Keyword.put_new(callback_opts, :owner, Keyword.get(opts, :owner))}
    else
      {:error, {:invalid_store_options, callback_opts}}
    end
  end

  @spec presenter_opts(keyword()) :: {:ok, keyword()} | {:error, term()}
  defp presenter_opts(opts) do
    case Keyword.get(opts, :presenter_opts, []) do
      presenter_opts when is_list(presenter_opts) ->
        if Keyword.keyword?(presenter_opts),
          do: {:ok, presenter_opts},
          else: {:error, {:invalid_presenter_options, presenter_opts}}

      presenter_opts ->
        {:error, {:invalid_presenter_options, presenter_opts}}
    end
  end

  @spec required_key(term(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  defp required_key(input, spectre_context, opts) do
    case optional_key(input, spectre_context, opts) do
      {:ok, nil} -> {:error, :directive_conversation_id_required}
      result -> result
    end
  end

  @spec optional_key(term(), term(), keyword()) :: {:ok, term() | nil} | {:error, term()}
  defp optional_key(input, spectre_context, opts) do
    owner = Keyword.get(opts, :owner)

    if is_atom(owner) and not is_nil(owner) do
      conversation_id =
        Keyword.get(opts, :directive_key) ||
          context_option(spectre_context, :directive_key) ||
          context_option(spectre_context, :conversation_id) ||
          state_conversation_id(spectre_context) ||
          input_meta(input, :conversation_id)

      namespace = Keyword.get(opts, :store_namespace, owner)
      {:ok, if(is_nil(conversation_id), do: nil, else: {namespace, conversation_id})}
    else
      {:error, :directive_owner_required}
    end
  end

  @spec context_option(term(), atom()) :: term()
  defp context_option(context, key) do
    case field(context, :opts, []) do
      opts when is_list(opts) -> Keyword.get(opts, key)
      _opts -> nil
    end
  end

  @spec turn_id(term()) :: term()
  defp turn_id(context), do: field(context, :turn_id) || context_option(context, :turn_id)

  @spec state_conversation_id(term()) :: term()
  defp state_conversation_id(context) do
    context |> field(:state, %{}) |> field(:conversation_id)
  end

  @spec input_meta(term(), atom()) :: term()
  defp input_meta(input, key), do: input |> field(:meta, %{}) |> fetch_value(key)

  @spec fetch(map(), atom()) :: {:ok, term()} | :error
  defp fetch(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, Atom.to_string(key))
    end
  end

  defp fetch(_map, _key), do: :error

  @spec fetch_value(map(), atom()) :: term()
  defp fetch_value(map, key) do
    case fetch(map, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  @spec start_options(term(), keyword()) :: keyword()
  defp start_options(input, opts) do
    opts
    |> Keyword.drop(@integration_option_keys)
    |> Keyword.put_new(:input, input_payload(input))
  end

  @spec input_payload(term()) :: term()
  defp input_payload(input), do: field(input, :raw) || field(input, :text) || input

  @spec runtime_options(keyword()) :: keyword()
  defp runtime_options(opts) do
    opts
    |> Keyword.take(@runtime_option_keys)
    |> Keyword.put_new(:execution, :auto)
  end

  @spec await_timeout(keyword()) :: timeout()
  defp await_timeout(opts) do
    case Keyword.get(opts, :await_timeout, @default_await_timeout) do
      :infinity -> :infinity
      timeout when is_integer(timeout) and timeout >= 0 -> timeout
      _invalid -> @default_await_timeout
    end
  end

  @spec with_mission(pid(), (-> term())) :: term()
  defp with_mission(mission, fun) when is_pid(mission) and is_function(fun, 0) do
    token = make_ref()
    caller = self()
    watcher = spawn(fn -> cleanup_on_exit(caller, mission, token) end)

    try do
      fun.()
    after
      send(watcher, {:release, token})
      _result = SpectreDirective.stop(mission)
    end
  end

  @spec cleanup_on_exit(pid(), pid(), reference()) :: :ok
  defp cleanup_on_exit(caller, mission, token) do
    monitor = Process.monitor(caller)

    receive do
      {:release, ^token} ->
        Process.demonitor(monitor, [:flush])
        :ok

      {:DOWN, ^monitor, :process, ^caller, _reason} ->
        _result = SpectreDirective.stop(mission)
        :ok
    end
  end

  @spec input_text(term()) :: String.t()
  defp input_text(input) do
    case field(input, :text, "") do
      text when is_binary(text) -> text
      value -> to_string(value)
    end
  end

  @spec normalize_choice(String.t()) :: String.t()
  defp normalize_choice(text), do: text |> String.trim() |> String.downcase()

  @spec field(term(), atom(), term()) :: term()
  defp field(value, key, default \\ nil)
  defp field(value, key, default) when is_map(value), do: Map.get(value, key, default)
  defp field(_value, _key, default), do: default
end
