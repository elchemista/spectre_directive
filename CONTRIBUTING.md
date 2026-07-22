# Contributing

Thanks for helping improve Spectre Directive. Contributions should preserve
the central boundary: Directive owns mission-loop state and transitions, while
applications own models, effects, policy, persistence, and user interaction.

## Development setup

CI runs with Elixir 1.19 and Erlang/OTP 28. After installing a compatible
toolchain:

```bash
mix deps.get
mix test
```

The test environment fetches the public Spectre repository to exercise the
optional Agent integration. The package itself does not require Spectre at
runtime.

## Before opening a pull request

Run the same checks used for release validation:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test --cover
mix credo
mix dialyzer
mix docs --warnings-as-errors
mix hex.publish --dry-run
```

Credo intentionally runs without `--strict`. New code should still resolve any
normal-priority issue reported by the configured default checks.

## Tests and documentation

- Add focused tests for observable behaviour and error contracts.
- Keep pure-engine tests asynchronous where they do not start shared runtime
  processes.
- Include documentation for new public modules, functions, types, decisions,
  and return shapes.
- Update `README.md`, examples, and `CHANGELOG.md` when user-visible behaviour
  changes.
- Avoid tests that depend on a network model provider or external service.

## Pull requests

Keep each pull request scoped to one coherent change. Explain the host boundary
affected, call out compatibility concerns, and include the commands used to
verify it. Changes to public structs or decision formats should explain the
migration path because those values may be persisted by host applications.

For vulnerabilities, follow [SECURITY.md](SECURITY.md) instead of opening a
public issue.
