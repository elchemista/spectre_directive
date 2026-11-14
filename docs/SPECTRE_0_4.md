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

## Who owns the loop

`Spectre.Stack` installs immutable capabilities and tool descriptors. The Agent
selects that Stack and declares routing; `Spectre.Server` owns the GenServer,
conversation, pending continuations and asynchronous results. Use
`use Spectre.Server, tools: MyApp.AI` to generate private helpers. A helper returns
an updated context containing a command; return that context from the callback.
It does not synchronously return the package's result. Tuple input chooses the
operation, and `on_result:` identifies the continuation in `handle_result/3`.

Preparation validates ordinary input before dispatch. The Server records command
identity/outbox state, invokes a worker, projects a bounded portable result and
acquires that result before the callback. Durable recovery needs a configured
checkpoint Store. Keep live clients and process handles in supervised resources
or process-local private context, not durable assigns. Native OTP callbacks remain
available; they use the same command-return boundary.

## Where GAM intervenes

The [Governed Act Model](https://spectre.guide/en/governed-act-model) separates
authority (Mandate), supporting facts (Evidence), the admitted execution record
(Act), and unresolved obligations (Duty). Installing a package connects a
capability; it does not grant authority to act on behalf of the end user.

A cognitive descriptor uses the tool worker path, without treating every model
call or classifier as a consent request. A governed descriptor becomes `propose`
before dispatch and uses the standard `Spectre.Server.GAM` bridge. Host-declared
surfaces still determine which effects, protected disclosures or resource uses
need governance; read-oriented operations are not categorically exempt from those
application boundaries. Ordinary configured cognition is not automatically a new
end-user authorization ceremony.

AgentServer automatically owns the GAM scope, Candidate preparation, authority
checks, consent Presentations, admitted execution and recorded results. Mounted
Skill Servers use that same Domain and authority ledger. The application enables
operations, supplies authenticated identity and business restrictions, and
presents the Server's consent requests; it does not implement a GAM Host.
`bind:` selects an operation reference and grants no authority. Native package
calls outside the Server do not acquire these guarantees automatically. Use the
[core automatic GAM APIs](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/MANAGED_GAM.md)
when an external process needs governed execution; directly invoking an effect
executor in a flow callback bypasses that boundary.

## Recovery and errors

These packages' cognitive helper operations declare safe replay; the runtime can
retry interrupted cognitive work according to the command lifecycle. A result is
still scoped to its original command. Application input rejections arrive as
`{:error, {:tool_rejected, tool, operation, reason}}`; library domain errors retain
the package's tagged result. Invalid installation/configuration is a developer
error, not a successful acquisition. The general `{:tool_unknown, details}` result
belongs to nonrepeatable tool operations; it is not an instruction to retry effects.

Governed effects use GAM recovery and their original command identities. An
ambiguous outcome remains unresolved: it must not be reported as proof of failure
or sent again blindly. A changed checkpoint fingerprint needs an explicit host
migration. Contract drift is handled by the core recovery rules rather than
invoking new adapter code with old arguments. See the
[core lifecycle](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/STACK_TOOLS.md)
and [AgentServer guide](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/AGENT_SERVER.md).

## Mounted Skill runtimes

Use the Stack-generated `directive` helper in a Skill's ordinary
`Spectre.Server` callbacks. The Agent mounts `Spectre.Skill, server: ...`; each
mount then owns its GenServer, state, workers, streams, pending intentions and
checkpoint key. No package-specific Skill adapter or extra installation is needed.

```text
AgentServer ─────┐
Research Skill ──┼──→ one automatic GAM boundary → same Domain / authority ledger
Knowledge Skill ┘
```

The root creates this connection once and passes it to the children. Do not
bootstrap another Domain, copy the ledger, implement a Skill Host or extend
ingress manually. Mounting grants no authority. Governed effects must satisfy
both root `gam:` operations and the mount's `governed:` references; scoped
Kinetic references keep their complete mounted scope. Ledger/Lab inspect the
calling runtime's checkpoint, not a copy of the shared GAM history.

The shared kernel orders admission while workers can run concurrently. Every
proposal retains its Skill invocation provenance. A confirmation belongs to the
originating mount and exact presentation, so it cannot approve a different
Skill's pending request. Timer expiry and closure enter the same lifecycle
ledger without erasing Acts, uncertain Outcomes or Duties. No per-Skill GAM
configuration is required.

See the [core shared/local ownership table and confirmation example](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/SKILLS.md),
[automatic GAM contract](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/MANAGED_GAM.md)
and [LiveView showcase](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/DEMO.md).
