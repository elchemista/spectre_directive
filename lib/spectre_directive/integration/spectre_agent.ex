defmodule SpectreDirective.Integration.SpectreAgent do
  @moduledoc """
  Optional adapter that routes Directive reasoning through a Spectre Agent.

  Spectre remains an optional runtime dependency. Calls cross that boundary
  dynamically, while the mission loop itself continues to depend only on
  Directive domain structs and behaviours. Spectre owns reasoning turns; the
  application-facing channel resumes user requests through Directive's
  `await_input/2`, `reply/3`, or subscription APIs.
  """

  @behaviour SpectreDirective.Reasoner

  alias SpectreDirective.AgentDecision
  alias SpectreDirective.Context
  alias SpectreDirective.Integration
  alias SpectreDirective.Integration.SpectreAgent.Codec
  alias SpectreDirective.Integration.SpectreAgent.Conversation
  alias SpectreDirective.Integration.SpectreAgent.DecisionResolver
  alias SpectreDirective.Integration.SpectreAgent.Prompt

  @spectre_module :"Elixir.Spectre"
  @spectre_llm_module :"Elixir.Spectre.LLM"
  @spectre_result_module :"Elixir.Spectre.Result"
  @spectre_turn_reply_module :"Elixir.Spectre.Turn.Handler.Reply"
  @response_key :spectre_directive_response

  @doc "Starts an authored directive whose reasoning turns use a Spectre Agent."
  @spec start(module(), binary() | atom() | nil, keyword()) :: {:ok, pid()} | {:error, term()}
  def start(owner, name, opts \\ []) when is_atom(owner) and is_list(opts) do
    agent = Keyword.get(opts, :spectre, Keyword.get(opts, :agent, owner))

    adapter_opts = [
      agent: agent,
      owner: owner,
      spectre_opts: Keyword.get(opts, :spectre_opts, [])
    ]

    runtime_opts =
      opts
      |> Keyword.drop([:spectre, :agent, :spectre_opts])
      |> Keyword.put(:directive, name)
      |> Keyword.put_new(:reasoner, {__MODULE__, adapter_opts})
      |> Keyword.put_new(:execution, :auto)

    SpectreDirective.start_directive(owner, runtime_opts)
  end

  @doc false
  @spec start_turn(module(), binary() | atom() | nil, term(), term(), keyword()) :: term()
  def start_turn(owner, name, input, spectre_context, opts \\ [])
      when is_atom(owner) and is_list(opts) do
    with :ok <- turn_handler_available(),
         {:ok, transition} <- Conversation.start(owner, name, input, spectre_context, opts) do
      conversation_result(input, spectre_context, transition, :started)
    end
  end

  @doc false
  @spec turn_reply(map()) :: term()
  def turn_reply(%{reply_text: reply_text, metadata: metadata}) do
    if Code.ensure_loaded?(@spectre_turn_reply_module) do
      {:reply,
       struct(@spectre_turn_reply_module,
         reply_text: reply_text,
         events: [%{type: :spectre_directive_resumed}],
         metadata: %{spectre_directive: metadata}
       )}
    else
      {:error, :spectre_turn_handler_unavailable}
    end
  end

  @doc false
  @spec decide(Context.t(), keyword()) :: AgentDecision.t() | {:error, term()}
  @impl SpectreDirective.Reasoner
  def decide(%Context{} = context, opts) when is_list(opts) do
    agent = Keyword.get(opts, :agent)
    owner = Keyword.get(opts, :owner)
    spectre_opts = Keyword.get(opts, :spectre_opts, [])

    with :ok <- available(agent, owner),
         {:ok, result} <- ask(agent, context, spectre_opts),
         {:ok, response} <- response(result),
         {:ok, decision} <- AgentDecision.new(response),
         {:ok, decision} <- DecisionResolver.resolve(owner, decision, context) do
      decision
    else
      {:error, reason} -> {:error, {:spectre_agent_reasoning_failed, reason}}
    end
  end

  @doc false
  @spec handle_turn(module(), term(), term()) :: term()
  def handle_turn(owner, input, spectre_context) do
    response =
      case directive_context(input) do
        {:ok, context} -> owner.handle_directive({:reason, context}, spectre_context)
        {:error, reason} -> {:error, reason}
      end

    spectre_result(input, spectre_context, response)
  end

  @doc "Uses the Agent's configured Spectre model for one default reasoning turn."
  @spec default_reason(module(), Context.t(), term()) :: term()
  def default_reason(_owner, %Context{} = context, spectre_context) do
    with :ok <- llm_available(),
         {:ok, prompt} <- Prompt.build(context),
         {:ok, text} <- complete(prompt, llm_opts(spectre_context)),
         {:ok, decoded} <- Codec.decode(text) do
      unwrap_decision(decoded)
    end
  end

  @spec available(term(), term()) :: :ok | {:error, term()}
  defp available(nil, _owner), do: {:error, :spectre_agent_required}
  defp available(_agent, nil), do: {:error, :directive_owner_required}

  defp available(_agent, _owner) do
    if Code.ensure_loaded?(@spectre_module),
      do: :ok,
      else: {:error, :spectre_unavailable}
  end

  @spec turn_handler_available() :: :ok | {:error, :spectre_turn_handler_unavailable}
  defp turn_handler_available do
    if Code.ensure_loaded?(@spectre_turn_reply_module),
      do: :ok,
      else: {:error, :spectre_turn_handler_unavailable}
  end

  @spec llm_available() :: :ok | {:error, :spectre_llm_unavailable}
  defp llm_available do
    if Code.ensure_loaded?(@spectre_llm_module),
      do: :ok,
      else: {:error, :spectre_llm_unavailable}
  end

  @spec ask(term(), Context.t(), keyword()) :: {:ok, term()} | {:error, term()}
  defp ask(agent, %Context{} = context, spectre_opts) when is_list(spectre_opts) do
    input = %{
      text: Integration.marker(),
      meta: %{
        spectre_directive_internal: true,
        spectre_directive_context: context
      }
    }

    opts =
      spectre_opts
      |> Keyword.put(:turn_handlers, false)
      |> Keyword.put(:via, [:regex])
      |> Keyword.put(:semantic_cache?, false)
      |> Keyword.put(:input_pipeline, [])
      |> Keyword.put_new(:chat_history_limit, false)

    # Spectre is deliberately optional, so this adapter cannot reference it
    # directly at compile time.
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(@spectre_module, :ask, [agent, input, opts])
  rescue
    error -> {:error, {:spectre_exception, error.__struct__, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:spectre_failure, kind, reason}}
  end

  @spec complete(binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  defp complete(prompt, opts) do
    # The model adapter is selected by Spectre from Agent/runtime options.
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(@spectre_llm_module, :complete, [prompt, opts])
  end

  @spec response(term()) :: {:ok, term()} | {:error, term()}
  defp response(%{metadata: metadata}) when is_map(metadata) do
    case Map.fetch(metadata, @response_key) do
      {:ok, response} -> {:ok, response}
      :error -> {:error, :missing_directive_response}
    end
  end

  defp response(result), do: {:error, {:invalid_spectre_result, result}}

  @spec directive_context(term()) :: {:ok, Context.t()} | {:error, term()}
  defp directive_context(%{meta: meta}) when is_map(meta) do
    meta
    |> context_value()
    |> normalize_context()
  end

  defp directive_context(input), do: {:error, {:invalid_spectre_input, input}}

  @spec context_value(map()) :: term()
  defp context_value(meta) do
    case Map.fetch(meta, :spectre_directive_context) do
      {:ok, context} -> context
      :error -> Map.get(meta, "spectre_directive_context")
    end
  end

  @spec normalize_context(term()) :: {:ok, Context.t()} | {:error, term()}
  defp normalize_context(%Context{} = context), do: {:ok, context}
  defp normalize_context(value), do: {:error, {:invalid_directive_context, value}}

  @spec spectre_result(term(), term(), term()) :: term()
  defp spectre_result(input, spectre_context, response) do
    if Code.ensure_loaded?(@spectre_result_module) do
      struct(@spectre_result_module,
        input: input,
        route: field(spectre_context, :route),
        state: field(spectre_context, :state),
        reply_text: "",
        events: [%{type: :spectre_directive_reasoned}],
        metadata: %{@response_key => response}
      )
    else
      {:error, :spectre_result_unavailable}
    end
  end

  @spec conversation_result(term(), term(), map(), atom()) :: term()
  defp conversation_result(input, spectre_context, transition, event) do
    if Code.ensure_loaded?(@spectre_result_module) do
      struct(@spectre_result_module,
        input: input,
        route: field(spectre_context, :route),
        state: field(spectre_context, :state),
        reply_text: transition.reply_text,
        events: [%{type: :spectre_directive_conversation, event: event}],
        metadata: %{spectre_directive: transition.metadata}
      )
    else
      {:error, :spectre_result_unavailable}
    end
  end

  @spec llm_opts(term()) :: keyword()
  defp llm_opts(%{opts: opts}) when is_list(opts), do: opts
  defp llm_opts(_spectre_context), do: []

  @spec unwrap_decision(term()) :: term()
  defp unwrap_decision(%{"decision" => decision}), do: decision
  defp unwrap_decision(%{decision: decision}), do: decision
  defp unwrap_decision(decision), do: decision

  @spec field(term(), atom()) :: term()
  defp field(value, key) when is_map(value), do: Map.get(value, key)
  defp field(_value, _key), do: nil
end
