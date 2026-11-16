# Directive with Spectre 0.4 AgentServer

[README](../README.md) · [Migration](MIGRATING_TO_0_4.md) · [Public API](PUBLIC_API.md)

## Helper contract

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

Extend the README Server with these continuations and a configured model/prompt:

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

Inside AgentServer use this pure helper. Native `SpectreDirective.new/next/respond`
returns explicit state for ordinary Elixir hosts. The optional standalone mission
runtime and Store behaviour are separate lifecycle choices, not automatically
started Stack resources for the new helper. Legacy `handle_directive` and
Turn-handler integration are retained in the
[reducer/OTP guide](REDUCER_AND_OTP_RUNTIME.md) and
[legacy Agent guide](SPECTRE_AGENT_INTEGRATION.md).

## Server lifecycle and Skills

Return the context produced by the helper. The Server queues the command and
delivers the result to `handle_result/3` with the `on_result:` tag. It owns
checkpointing, pending consent and recovery; package installation grants no
authority. An uncertain effect needs reconciliation rather than a blind retry.

The helper also works in mounted Skill Servers, which share the root GAM Domain
and keep separate state and checkpoints. See [Stack tools](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/STACK_TOOLS.md),
[Managed GAM](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/MANAGED_GAM.md) and the [Skill guide](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/SKILLS.md)
for the shared runtime contracts. Native APIs remain caller-owned.
