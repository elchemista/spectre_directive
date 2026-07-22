# Examples

The examples are complete programs that can be run from the repository root.
They use deterministic local functions, so no network service or model API key
is required.

| Example | What it demonstrates | Command |
| --- | --- | --- |
| `pure_loop.exs` | Manually driving every pure reducer boundary | `mix run examples/pure_loop.exs` |
| `automatic_runtime.exs` | Supervised automatic reasoner and invocation execution | `mix run examples/automatic_runtime.exs` |
| `dsl_showcase.exs` | Named directives, all authored DSL declarations, policy, and completion callbacks | `mix run examples/dsl_showcase.exs` |
| `spectre_agent.exs` | Spectre Agent questions, repeated replies, a trusted symbolic invocation, and completion | `MIX_ENV=test mix run examples/spectre_agent.exs` |

The Spectre Agent example uses `MIX_ENV=test` because Spectre is intentionally a
test-only dependency of this repository. Published applications should depend
on both `:spectre` and `:spectre_directive` themselves.

## Authored DSL declarations

A module starts with `use Spectre.Directive` and may contain multiple
`directive` blocks. Each block supports:

- `mission` or its alias `objective` for the goal;
- `context`, `success`, `mode`, and `directive_metadata` for mission-level
  configuration;
- zero or more `step` blocks;
- `on_complete` for one trusted callback after successful mission completion.

A step may use `kind`, `flexibility`, `purpose`, `reason`, `prompt`, `expects`,
`done_when`, `risk`, `input`, `metadata`, `policy`, and `invoke`. See
`dsl_showcase.exs` for these declarations together in one runnable flow.

## Spectre Agent integration

In an Agent module, call `use Spectre.Agent` before `use Spectre.Directive`.
Directive then adds an internal route and generates `start_directive/2`.

Override `handle_directive({:reason, context}, spectre_context)` for custom
reasoning, or keep the default callback to use the model configured by Spectre.
Resolve every model-generated symbolic invocation in
`handle_directive({:invocation, name}, context)`. Returning an executable
function, behaviour module, or MFA explicitly marks that target as trusted;
unresolved strings are never executed.

The runnable Agent example also shows the application-facing conversation
contract. `await_input/2` returns the first question; each `reply/3` returns
either another user-owned request or the terminal outcome. For event-driven
channels, use mission subscriptions and correlated `respond/3` calls instead.
See the full [Spectre Agent integration guide](../docs/SPECTRE_AGENT_INTEGRATION.md).
