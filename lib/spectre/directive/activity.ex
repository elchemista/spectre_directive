defmodule Spectre.Directive.Activity do
  @moduledoc """
  Drives a Directive mission through the AgentServer's commands and checkpoints.

  After installing `Spectre.Directive`, start the mission from a Server callback:

      start_activity(ctx, {:directive, :mission}, %{
        goal: input.text,
        tools: %{"read_document" => {:documents, :read}}
      })

  The Agent supplies the model. The default `:mission` asset sends the mission
  protocol, current context and allowed aliases. A model invocation has the
  shape `%{"kind" => "invoke", "target" => "read_document", "args" => %{}}`.
  Arguments retain JSON keys and go through the registered tool's adapter.
  Use `scope:` on the start command to narrow the Activity's Stack access.

  Use `mode: :guided` to ask before applying a plan or patch. The default is
  `:autonomous`. `answer_timeout` is measured in milliseconds and defaults to
  60,000. An optional `prompt` selects an asset under the Activity's prompt root.
  Mission questions come through the Root's Activity lifecycle, with an explicit
  reply reference. Governed tool consent uses the Root's GAM decision API.

  For an application-specific Activity, `use Spectre.Directive.Activity` and
  implement `c:handle_invocation/3` to act on a tool result. The built-in
  mission continues through Directive by default.
  """

  use Spectre.Activity, prompt_root: {:priv, :spectre_directive, "prompts"}

  alias Spectre.Directive.ServerTool
  alias Spectre.JSON
  alias Spectre.Server.Context
  alias Spectre.Stack.Tools
  alias Spectre.Stack.Value, as: StackValue
  alias SpectreDirective.{AgentDecision, Outcome, Request}
  alias SpectreDirective.Integration.SpectreAgent.Codec
  alias SpectreDirective.Loop.Engine

  @typedoc "The correlated tool request, with the original arguments supplied to the adapter."
  @type invocation :: %{
          request_id: binary(),
          tool: {atom() | binary() | integer() | tuple(), atom()},
          args: map(),
          plan_version: pos_integer()
        }

  @doc """
  Handles the current Directive invocation's result.

  The result is the same value delivered by the Server's command continuation.
  For a governed operation it is `{:governed, result}`. `invocation.args` holds
  the arguments before tool preparation. Use the governed outcome or your
  application's persisted effect data when you need the authoritative material.

  Return `:cont` to let Directive reason about the result, or return the supplied
  Context with your changes and commands to take over the Activity. When
  checkpointing is enabled, Spectre saves the handoff with those changes.
  The application then owns subsequent commands and signals. Handle command results via
  `c:Spectre.Server.handle_result/3` as usual. An unconfirmed result requires
  reconciliation and fails the mission before this callback runs.
  """
  @callback handle_invocation(invocation(), term(), Context.t()) :: :cont | Context.t()

  @doc """
  Uses Directive's mission callbacks in an application Activity.

  The options follow `Spectre.Activity` and default to Directive's packaged
  mission prompt root. Override `handle_invocation/3` to customize how a
  correlated tool result advances an application workflow.
  """
  @spec __using__(keyword()) :: Macro.t()
  defmacro __using__(opts) do
    opts =
      Keyword.put_new(opts, :prompt_root, Macro.escape({:priv, :spectre_directive, "prompts"}))

    quote do
      use Spectre.Activity, unquote(opts)

      @behaviour Spectre.Directive.Activity

      @impl Spectre.Activity
      def handle_start(args, ctx), do: Spectre.Directive.Activity.handle_start(args, ctx)

      @impl Spectre.Activity
      def handle_signal(signal, ctx), do: Spectre.Directive.Activity.handle_signal(signal, ctx)

      @impl Spectre.Server
      def handle_result({:directive, _id} = tag, result, ctx),
        do: Spectre.Directive.Activity.handle_result(__MODULE__, tag, result, ctx)

      def handle_result(tag, result, ctx), do: super(tag, result, ctx)

      @impl Spectre.Directive.Activity
      def handle_invocation(_invocation, _result, _ctx), do: :cont

      defoverridable handle_start: 2, handle_signal: 2, handle_result: 3, handle_invocation: 3
    end
  end

  @mission_options [
    :goal,
    :mission,
    :context,
    :success,
    :success_criteria,
    :constraints,
    :risk_boundaries,
    :information,
    :steps,
    :plan,
    :mode,
    :max_iterations
  ]

  @doc """
  Starts reasoning for an authored mission or a goal map.

  The map can supply the allowed tool aliases, a prompt asset and a user-answer
  timeout. Return the Context to the Activity runtime to acquire its next command.
  """
  @impl Spectre.Activity
  @spec handle_start(term(), Context.t()) :: Context.t()
  def handle_start(attrs, ctx) when is_map(attrs) do
    options = attrs |> Map.take(@mission_options) |> Map.put_new(:mode, :autonomous)

    with {:ok, settings} <- settings(attrs),
         {:ok, state} <- SpectreDirective.new(options) do
      ctx = assign(ctx, %{directive_settings: settings, directive_handoff: nil})
      advance(SpectreDirective.next(state), ctx)
    else
      {:error, reason} -> failed(ctx, reason)
    end
  end

  def handle_start(_args, ctx), do: fail(ctx, :invalid_mission_arguments)

  @doc """
  Advances the default mission from a correlated command result.

  Directive supplies its own result tag. Application-specific result handlers
  use the normal Server continuation and delegate other clauses with `super/3`.
  """
  @impl Spectre.Server
  @spec handle_result(term(), term(), Context.t()) :: Context.t()
  def handle_result({:directive, _id} = tag, result, ctx),
    do: handle_result(__MODULE__, tag, result, ctx)

  @doc false
  @spec handle_invocation(invocation(), term(), Context.t()) :: :cont
  def handle_invocation(_invocation, _result, _ctx), do: :cont

  @doc false
  @spec handle_result(module(), term(), term(), Context.t()) :: Context.t()
  def handle_result(
        _activity,
        {:directive, _id},
        _result,
        %{assigns: %{directive_handoff: %{}}} = ctx
      ),
      do: no_response(ctx)

  def handle_result(activity, {:directive, id}, result, ctx) do
    case restore(ctx) do
      {:ok, %{pending_request: %Request{id: ^id} = request} = state} ->
        accept_result(activity, request, state, result, ctx)

      {:ok, _state} ->
        ctx

      {:error, reason} ->
        failed(ctx, reason)
    end
  end

  @doc """
  Applies a revision or observes an admitted GAM effect from a previous revision.

  A revision retires the old request and starts reasoning again. If the
  application owns the continuation after a handoff, it also owns later signals.
  """
  @impl Spectre.Activity
  @spec handle_signal(term(), Context.t()) :: Context.t()
  def handle_signal(_signal, %{assigns: %{directive_handoff: %{}}} = ctx), do: ctx

  def handle_signal({:revise, notes}, ctx) do
    with {:ok, state} <- restore(ctx),
         {:ok, updated} <- Engine.revise(state, %{revision: notes}) do
      advance(SpectreDirective.next(updated), retire_invocation(ctx, state.pending_request))
    else
      {:error, reason} -> failed(ctx, reason)
    end
  end

  def handle_signal({:effect, {:governed, effect}}, ctx) do
    with {:ok, observed} <- observed_effect(effect),
         {:ok, state} <- restore(ctx),
         {:ok, updated} <- SpectreDirective.inform(state, observed, source: :effect) do
      case updated.pending_request do
        nil -> advance(SpectreDirective.next(updated), ctx)
        _pending -> persist(updated, ctx)
      end
    else
      {:error, reason} -> failed(ctx, reason)
    end
  end

  def handle_signal(_signal, ctx), do: ctx

  defp accept_result(
         _activity,
         %Request{kind: :invoke, id: id},
         state,
         {:error, {:tool_rejected, _, _, _}} = result,
         ctx
       ),
       do: advance(SpectreDirective.respond(state, id, result), ctx)

  defp accept_result(activity, request, state, result, ctx) do
    case answer(request, result) do
      {:ok, answer} when request.kind == :invoke ->
        handle_invocation_result(activity, request, state, result, answer, ctx)

      {:ok, answer} ->
        advance(SpectreDirective.respond(state, request.id, answer), ctx)

      {:error, reason} ->
        failed(ctx, reason)
    end
  end

  defp handle_invocation_result(activity, request, state, result, answer, ctx) do
    with {:ok, tool, args} <- invocation(request.target, ctx),
         {:ok, updated} <- Engine.accept_response(state, request.id, answer) do
      invocation = %{
        request_id: request.id,
        tool: tool,
        args: args,
        plan_version: request.plan_version
      }

      case activity.handle_invocation(invocation, result, ctx) do
        :cont -> advance(SpectreDirective.next(updated), ctx)
        %Context{} = returned -> checkpoint_handoff(updated, invocation, returned, ctx)
        _other -> failed(ctx, :invalid_invocation_callback_result)
      end
    else
      {:error, reason} -> failed(ctx, reason)
    end
  end

  defp checkpoint_handoff(state, invocation, returned, ctx) do
    marker = Map.delete(invocation, :args)
    returned = if returned.commands == [], do: no_response(returned), else: returned

    case checkpoint(state, assign(returned, :directive_handoff, marker)) do
      {:ok, saved} -> saved
      {:error, reason} -> failed(ctx, reason)
    end
  end

  defp restore(ctx), do: ServerTool.decode(Map.get(ctx.assigns, :directive_state))

  defp checkpoint(state, ctx) do
    with {:ok, encoded} <- ServerTool.encode(state),
         do: {:ok, assign(ctx, :directive_state, encoded)}
  end

  defp persist(state, ctx) do
    case checkpoint(state, ctx) do
      {:ok, saved} -> saved
      {:error, reason} -> failed(ctx, reason)
    end
  end

  defp advance({:request, request, state}, ctx) do
    case checkpoint(state, ctx) do
      {:ok, saved} -> dispatch(request, state, saved)
      {:error, reason} -> failed(ctx, reason)
    end
  end

  defp advance({:done, %Outcome{status: :completed} = outcome, _state}, ctx),
    do: complete(ctx, Map.take(outcome, [:mission_id, :result]))

  defp advance({:done, %Outcome{} = outcome, _state}, ctx), do: failed(ctx, outcome.reason)
  defp advance({_status, reason, _state}, ctx), do: failed(ctx, reason)

  defp dispatch(%Request{kind: :reason, id: id, context: context}, _state, ctx) do
    %{prompt: prompt, tools: tools} = ctx.assigns.directive_settings

    payload =
      context
      |> SpectreDirective.reasoning_input()
      |> Map.put(:tools, model_tools(ctx.agent, tools))
      |> Codec.json_value()

    generate(ctx, prompt, assigns: %{directive: payload}, on_result: {:directive, id})
  end

  defp dispatch(%Request{kind: :invoke, id: id, target: target}, state, ctx) do
    with {:ok, ref, args} <- invocation(target, ctx),
         false <- invocation_retired?(ctx, ref, args) do
      call_tool(ctx, ref, args, on_result: {:directive, id})
    else
      true ->
        error = {:error, :superseded_invocation_requires_reconciliation}
        advance(SpectreDirective.respond(state, id, error), ctx)

      {:error, {:unknown_mission_tool, _name}} = error ->
        advance(SpectreDirective.respond(state, id, error), ctx)

      {:error, reason} ->
        failed(ctx, reason)
    end
  end

  defp dispatch(%Request{} = request, _state, ctx) do
    await_input(ctx, :directive_answer,
      prompt: question(request),
      timeout: ctx.assigns.directive_settings.answer_timeout,
      on_result: {:directive, request.id}
    )
  end

  defp question(%Request{kind: :question, payload: %{question: text}}), do: display(text)

  defp question(%Request{kind: :confirmation, payload: %{proposal: proposal}}),
    do: "Approve this mission plan change? Reply yes or no.\n" <> display(proposal)

  defp question(%Request{kind: :policy, payload: %{policy: policy}}),
    do: "Approve this mission policy request? Reply yes or no.\n" <> display(policy)

  defp model_tools(agent, tools) do
    {:ok, %{stack: stack}} = Spectre.Definition.fetch(agent)

    Map.new(tools, fn {label, ref} ->
      metadata =
        case Spectre.Stack.tool_metadata(stack, ref) do
          {:ok, metadata} -> Map.take(metadata, [:description, :arguments])
          {:error, _} -> %{}
        end

      {label, metadata}
    end)
  end

  defp display(value) when is_binary(value), do: value
  defp display(value), do: inspect(value, limit: 16, printable_limit: 2_000)

  defp answer(%Request{kind: :invoke}, {:governed, effect}), do: observed_effect(effect)

  defp answer(%Request{kind: :invoke}, {kind, details})
       when kind in [:governed_unknown, :tool_unknown],
       do: {:error, {:unconfirmed_tool, details}}

  defp answer(_request, {:error, reason}), do: {:error, reason}
  defp answer(%Request{kind: :invoke}, result), do: {:ok, result}

  defp answer(%Request{kind: :reason}, {:generated, %{text: text} = reply}) do
    case JSON.decode(Map.get(reply, :model_output, text)) do
      {:ok, %{} = decoded} -> decision(decoded)
      _invalid -> {:error, :invalid_mission_decision}
    end
  end

  defp answer(%Request{kind: kind}, {:ok, %Spectre.Input{text: text}})
       when kind in [:confirmation, :policy],
       do: {:ok, String.downcase(String.trim(text)) in ["yes", "approve", "sì", "si", "confermo"]}

  defp answer(%Request{kind: :question}, {:ok, %Spectre.Input{text: text}}), do: {:ok, text}
  defp answer(_request, _result), do: {:error, :invalid_mission_response}

  defp decision(%{"kind" => "invoke", "target" => name} = value) when is_binary(name),
    do: AgentDecision.new({:invoke, %{"target" => name, "args" => Map.get(value, "args", %{})}})

  defp decision(value), do: AgentDecision.new(value)

  defp observed_effect(effect) do
    case observation(effect) do
      %{status: status} = details when status in [:ambiguous, :unconfirmed] ->
        {:error, {:unconfirmed_tool, details}}

      outcome ->
        {:ok, outcome}
    end
  end

  defp observation(%{outcome: %{ref: ref, act_ref: act, status: status}}),
    do: %{act_ref: act, outcome_ref: ref, status: status}

  defp observation(%{act: nil, proposal: %{fallback: %{result: %{act: act} = fallback}}})
       when not is_nil(act),
       do: observation(fallback)

  defp observation(%{act: nil, decision: %{outcome: decision}}),
    do: %{status: :not_admitted, decision: decision}

  defp observation(%{act: %{ref: ref}}), do: %{status: :unconfirmed, act_ref: ref}
  defp observation(_effect), do: %{status: :unconfirmed}

  defp invocation(%{"target" => name} = target, ctx),
    do: invocation(name, Map.get(target, "args", %{}), ctx)

  defp invocation(name, ctx), do: invocation(name, %{}, ctx)

  defp invocation(name, args, ctx) when is_binary(name) and is_map(args) do
    case Map.fetch(ctx.assigns.directive_settings.tools, name) do
      {:ok, ref} -> {:ok, ref, args}
      :error -> {:error, {:unknown_mission_tool, name}}
    end
  end

  defp invocation(_name, _args, _ctx), do: {:error, :invalid_mission_invocation}

  defp retire_invocation(ctx, %Request{kind: :invoke, target: target}) do
    with {:ok, ref, args} <- invocation(target, ctx),
         true <- governed?(ctx.agent, ref) do
      key = invocation_key(ref, args)
      assign(ctx, :directive_retired, [key | Map.get(ctx.assigns, :directive_retired, [])])
    else
      _ -> ctx
    end
  end

  defp retire_invocation(ctx, _request), do: ctx

  defp governed?(agent, {package, operation} = ref) do
    with {:ok, installation} <- Spectre.Stack.installation(agent, package),
         %{snapshot: %{descriptor: descriptor}} <-
           Map.get(Tools.scoped_table!([installation]), ref) do
      match?(%{path: :governed}, descriptor.operations[operation])
    else
      _missing -> false
    end
  end

  defp invocation_retired?(ctx, ref, args),
    do: invocation_key(ref, args) in Map.get(ctx.assigns, :directive_retired, [])

  defp invocation_key(ref, args),
    do: :crypto.hash(:sha256, :erlang.term_to_binary({ref, args}, [:deterministic]))

  defp settings(attrs) do
    tools = Map.get(attrs, :tools, %{})
    prompt = Map.get(attrs, :prompt, :mission)
    timeout = Map.get(attrs, :answer_timeout, 60_000)

    with true <- is_atom(prompt) or is_binary(prompt),
         true <- is_integer(timeout) and timeout in 1..4_294_967_295,
         true <- is_map(tools) and Enum.all?(tools, &tool_alias?/1) do
      {:ok, %{tools: tools, prompt: prompt, answer_timeout: timeout}}
    else
      false -> {:error, :invalid_mission_options}
    end
  end

  defp tool_alias?({name, {installation, operation}}) do
    is_binary(name) and byte_size(name) > 0 and StackValue.valid_id?(installation) and
      is_atom(operation) and operation not in [nil, true, false]
  end

  defp tool_alias?(_entry), do: false

  defp failed(ctx, reason) do
    case ServerTool.project(:error, {:error, reason}) do
      {:ok, {:error, portable}} -> fail(ctx, portable)
      _invalid -> fail(ctx, :invalid_mission_state)
    end
  end
end
