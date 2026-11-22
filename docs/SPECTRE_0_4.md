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

The Activity starts an autonomous mission using `goal`. The optional `tools`
map gives the model names for installed Stack bindings. `scope:` limits the
Activity's access for this execution. For a mission that only needs the model,
pass the goal by itself.

`mode: :guided` asks before applying a plan or patch. Supply `steps:` when
the application has an authored plan, `max_iterations:` for a mission's
reasoning budget, and `answer_timeout:` to override the default 60-second
wait. The default mode is `:autonomous`.

The Root receives lifecycle events as
`{Spectre.Server, root, {:activity, identity, event}}`. `identity.ref` selects
one execution. An Activity can start, request input, complete with
`{:completed, %{mission_id: id, result: result}}`, or report a failure.
Implement `handle_activity/3` on the Server when the application needs to
react in a callback.

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

Free-text answers are explicitly addressed. Other messages can still reach the
Root's ordinary routes while a mission waits. An authorized caller can inspect
the mission with `Spectre.Server.activity/2`, revise it with
`Spectre.Server.signal_activity(root, ref, {:revise, notes})`, or stop it with
`Spectre.Server.cancel_activity(root, ref)`. The same control requests are
available in Server callbacks with the context as the first argument. A
revision starts reasoning with the new information and invalidates old waits.

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

The integration test exercises this path with two missions, a deterministic
model, and a GAM-governed effect. From this repository, run
`SPECTRE_PATH=../spectre mix test test/directive_activity_test.exs`.

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
