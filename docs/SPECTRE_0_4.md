# Directive with Spectre 0.4.1 AgentServer

[README](../README.md) · [Migration](MIGRATING_TO_0_4.md) · [Public API](PUBLIC_API.md)

## Start a mission

Install `Spectre.Directive` in the Stack and configure the Agent's model as
shown in the [README](../README.md). In the Server's selected flow, return
the context from `start_activity/4`.

```elixir
def handle_flow({:research, :start}, input, ctx) do
  start_activity(ctx, {:directive, :mission}, %{
    goal: input.text,
    tools: %{"publish" => {:documents, :publish}}
  }, scope: [{:documents, :publish}])
end
```

The second argument is the installed Activity type. The map is the mission
configuration and the trailing keyword list configures the Core start command.
`scope:` limits access for this execution. For a reasoning-only mission, pass
the goal by itself.

| Mission map field | Input and purpose |
| --- | --- |
| `goal` or `mission` | A non-empty objective. Pass a string in `goal` or a `SpectreDirective.Mission` or mission attribute map in `mission`. When supplying an authored mission, put its context and criteria in that value. |
| `context` | Portable application context for a string goal, for example the recent turns needed to understand a reference. |
| `success_criteria` or `success` | Desired result for a string goal, for example a comparison containing a recommendation. |
| `constraints`, `risk_boundaries` | Guidance for planning, such as a preferred language or an instruction to stop when data is missing. The host separately defines the actual tool and GAM permissions. |
| `information` | Initial information entries available to the reducer. |
| `steps` or `plan` | An authored starting plan. `steps` supplies step definitions. `plan` supplies a plan or plan attributes and takes precedence when present. |
| `mode` | `:autonomous` by default. Use `:guided` for confirmation before applying a proposed plan or patch. |
| `max_iterations` | Positive reducer budget, default 100. Tool errors and corrective decisions use the same budget. |
| `tools` | Map of string aliases to installed `{installation, operation}` pairs. Default is an empty map. Tool arguments from model JSON use string keys. |
| `prompt` | Name or path of a prompt asset under the Activity's prompt root. The default is Directive's `:mission` prompt. |
| `answer_timeout` | Positive timeout in milliseconds for a mission answer. Default is 60,000. |

Use the separate Core command options for `as:`, `scope:`, and an optional
`on_result:` tag for the start result. A tag identifies a continuation on
the Root. Lifecycle events carry the execution reference and the final result.

The Root receives lifecycle events as
`{Spectre.Server, root, {:activity, identity, event}}`. `identity.ref` selects
one execution. An Activity can start, request input, complete with
`{:completed, %{mission_id: id, result: result}}`, or report a failure.
Implement `handle_activity/3` on the Server when the application needs to
react in a callback.

Two calls to `start_activity/4` create separate executions. Use `as: :report`
when the application wants a named execution. The key can be reused after the
previous execution ends. `Spectre.Server.activity(root, :report)` resolves the
current execution. Lifecycle events carry their original `identity.ref`, so
an event from an earlier report stays associated with that report after reuse.

## Answer a question and revise a mission

When a mission requests information, show the `prompt` from its waiting event
and keep the Activity reference and the wait's ID and revision. Send the reply
through the Root.

```elixir
receive do
  {Spectre.Server, ^root,
   {:activity, %{ref: ref}, {:waiting_input, %{id: id, revision: revision,
                                             prompt: question}}}} ->
    answer = MyApp.UI.ask(question)
    Spectre.Server.input(root, answer, activity: ref, pending: {id, revision})
end
```

Here `root` is the server PID and `MyApp.UI.ask/1` stands for the application's
UI. `ref` selects the Activity, and `{id, revision}` addresses this version
of the question. Free-text answers are explicitly addressed. Other messages can still reach the
Root's ordinary routes while a mission waits. An authorized caller can inspect
the mission with `Spectre.Server.activity/2`, revise it with
`Spectre.Server.signal_activity(root, ref, {:revise, notes})`, or stop it with
`Spectre.Server.cancel_activity(root, ref)`. The same control requests are
available in Server callbacks with the context as the first argument. A
revision starts reasoning with the new information and invalidates old waits.
Use `if_revision:` with a trusted snapshot to avoid applying a revision to
newer work. The returned request ID acknowledges that the control was queued.
Read its `{:signalled, request_id, result}` event for the applied result.

## Model decisions and GAM effects

The default mission prompt supplies the reducer context, decision protocol and
the names of available tools. The model returns one JSON decision. These are
three examples of responses on separate inference calls.

```json
{"kind":"ask","question":"Which document should I publish?"}
{"kind":"invoke","target":"publish","args":{"id":"D12"}}
{"kind":"complete_mission","result":"Document D12 published"}
```

Directive submits tool calls through `call_tool/4` with the mapped binding.
For `publish`, the Stack must register a governed binding and the host must
configure the GAM operation. If confirmation is required, use the usual Root
presentation and decision APIs. A reply to the mission's question supplies
information for planning. Approval uses the GAM presentation reference.
Directive feeds an observed outcome back into reasoning and reports uncertain
effects for reconciliation through the host.

An unknown alias or a tool preparation rejection goes back to the model as a
tool error. The model can correct the request or finish the mission. These
decisions use the same `max_iterations:` budget as other reasoning steps.
An invocation retired by a revision also returns an error and stays blocked.

The integration test exercises this path with two missions, a deterministic
model, and a GAM-governed effect. It also checks failure isolation and named
reuse. From this repository, run
`SPECTRE_PATH=../spectre mix test test/directive_activity_test.exs`. Run
`SPECTRE_PATH=../spectre mix run examples/agent_server_activity.exs` to classify
ordinary text, keep chat history, start two unnamed missions and keep chatting.
The script revises one by its reference, answers the other, and shows how the
default lifecycle reports a provider failure. Its local adapters use fixed
responses for reproducibility. A production app can configure separate
classifier, chat and mission inference providers.

## Continue a workflow after a tool result

Use the built-in Activity when Directive should decide what to do next. If the
next step follows a rule you already know, keep that rule in Elixir. A custom
Activity can inherit the mission callbacks and act on a correlated tool result.

```elixir
defmodule MyApp.Publication do
  use Spectre.Directive.Activity

  @impl Spectre.Directive.Activity
  def handle_invocation(
        %{tool: {:documents, :publish}},
        {:governed, %{outcome: %{status: :succeeded, ref: receipt}}},
        ctx
      ) do
    complete(ctx, %{result: "Document published", receipt: receipt})
  end

  def handle_invocation(_invocation, _result, _ctx), do: :cont
end
```

Register it with `activity :publication, MyApp.Publication` in your Stack and
start `:publication` with the same mission options and tool scope as the built-in
Activity. The callback receives the request ID, tool reference, original
arguments and plan version. The arguments are the input to the adapter. Use the
governed outcome or your application's persisted effect data for material that
the adapter normalized before admission.

Return `:cont` to let Directive use the observed result and continue reasoning.
Return the Activity context to take over the rest of the workflow. You can
complete it immediately or issue another command and handle that result with
`handle_result/3`. Governed commands still go through GAM. With checkpointing,
Spectre stores the handoff alongside the commands. A later Directive result or
revision leaves the continuation with the application. To start fresh
reasoning within the same Activity, the application can explicitly call its
`handle_start/2` with new mission options after resolving any in-flight
effects. An ambiguous or unconfirmed outcome requires reconciliation.

## Manual reducer helper

An application can still drive the reducer itself from Server callbacks.
Select your Stack with `use Spectre.Server, tools: MyApp.Stack` to get the
generated `directive(ctx, request, on_result: :mission)` helper.

| Input | Meaning |
| --- | --- |
| `{:new, attrs}` | Create a pure mission and advance to its first boundary |
| `{:next, encoded_state}` | Return its pending request or advance the reducer |
| `{:respond, encoded_state, request_id, answer}` | Apply one correlated host answer |
| `{:inform, encoded_state, information}` | Add information and advance |

All four operations are cognitive and safely replayable. They call the existing
`SpectreDirective` pure API; they never invoke a reasoner, target function, policy
callback or optional mission process. There is no default operation and no
Directive `bind:` effect operation.

The result is `{:directive, %{status: status, state: encoded, data: data}}`, where
status is `:request`, `:done`, `:blocked` or `:error`. State is a bounded canonical
binary (900,000 bytes); the descriptor limit is 1 MiB. Requests/outcomes are plain
projected data. Save only the current encoded state and required correlation data
in assigns. A normal two-element domain error is `{:error, reason}`.

## Connect reasoning without hiding it in the reducer

Use these continuations with a configured model and prompt when you drive the
reducer manually.

```elixir
def handle_result(:mission,
    {:directive, %{status: :request, state: encoded,
                   data: %{kind: :reason} = request}}, ctx) do
  ctx
  |> assign(:mission_state, encoded)
  |> assign(:mission_request_id, request.id)
  |> generate(:mission_decision,
    assigns: %{request: request}, on_result: :decision)
end

def handle_result(:decision, {:generated, response}, ctx) do
  case MyApp.Decisions.decode(response.text) do
    {:ok, answer} ->
      directive(ctx,
        {:respond, ctx.assigns.mission_state, ctx.assigns.mission_request_id, answer},
        on_result: :mission)
    {:error, _} ->
      respond(ctx, "I could not read the proposed mission decision.")
  end
end
```

`MyApp.Decisions.decode/1` is application code that validates model output against
Directive's decision protocol. It is not a hidden library function. For a plan
request, one valid answer is `{:propose_plan, [%{id: "read", title: "Read page"}]}`.
Other requests must receive answers appropriate to their kind and current state.
Late or stale request ids cannot advance a newer reducer state.

## Requests, effects and confirmation

A `:question` request is a need for information; retain its id/state and feed the
user's answer through `:respond`. A reducer `:confirmation` or `:policy` request
belongs to the mission protocol. Approving a plan does not authorize all its
future effects under GAM.

For `:invoke`, resolve the declared target through a host allowlist and stage
`propose(ctx, operation, args, on_result: :mission_effect)` (or the installed
package's governed helper). Do not execute arbitrary model-supplied MFA/function
values. Remember the reducer request id, then return the **observed** governed
result to that request. For example, after a succeeded GAM outcome the host may
answer `{:complete_step, %{act_ref: outcome.act_ref, status: outcome.status}}`.
An ambiguous outcome does not justify completing the step as succeeded; retain
the unresolved duty and reconcile it through the host/GAM path.

Portable reducer state may contain descriptive module/MFA targets, but never
callback functions, PIDs or browser/client structs. The host still controls target
resolution; portable data is not permission to execute it.

## Lifecycle choices

Native `SpectreDirective.new/next/respond` returns explicit state for ordinary
Elixir hosts. The optional standalone mission runtime and Store behaviour are
separate lifecycle choices. Legacy `handle_directive` and Turn-handler
integration are documented in the
[reducer/OTP guide](REDUCER_AND_OTP_RUNTIME.md) and
[legacy Agent guide](SPECTRE_AGENT_INTEGRATION.md).

## Server lifecycle and Skills

Return the context produced by the helper. The Server queues the command and
delivers the result to `handle_result/3` with the `on_result:` tag. It owns
checkpointing, pending consent and recovery; package installation grants no
authority. An uncertain effect needs reconciliation rather than a blind retry.

The helper also works in mounted Skill Servers, which share the root GAM Domain
and keep separate state and checkpoints. See [Stack tools](https://github.com/elchemista/spectre/blob/0.4.0/docs/STACK_TOOLS.md),
[Managed GAM](https://github.com/elchemista/spectre/blob/0.4.0/docs/MANAGED_GAM.md) and the [Skill guide](https://github.com/elchemista/spectre/blob/0.4.0/docs/SKILLS.md)
for the shared runtime contracts. Native APIs remain caller-owned.
