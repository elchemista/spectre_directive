# Spectre Directive public API — 0.1.6 baseline

This file is the normative public API manifest for the recoverable `0.1.6`
baseline. Compatibility guarantees apply only to the modules and callables
listed below. Any module, function, macro, or callback not listed here is an
implementation detail even when it is exported or visible in generated docs.

Default arguments are expanded into every callable arity. For the listed
modules, documented types, opaque types, and documented struct fields are also
public. Modules with no callable row expose only their documented module,
type, and struct contract.

## Manifest

- `Spectre.Directive`
  - functions: `assign/2`, `await/1`, `await/2`, `await_input/1`, `await_input/2`, `cancel/1`, `cancel/2`, `child_spec/1`, `config/1`, `context/1`, `context_map/1`, `control/2`, `create/1`, `inform/2`, `inform/3`, `new/1`, `next/1`, `outcome/1`, `pause/1`, `plan/1`, `protocol/0`, `pulse/1`, `reasoning_input/1`, `reply/2`, `reply/3`, `request/1`, `respond/2`, `respond/3`, `resume/1`, `start_directive/1`, `start_directive/2`, `start_link/0`, `start_link/1`, `start_loop/1`, `start_loop/2`, `start_mission/1`, `start_mission/2`, `state/1`, `stop/1`, `subscribe/1`, `subscribe/2`, `trace/1`
  - macros: `__using__/1`
- `Spectre.Directive.Handler`
  - callbacks: `handle_directive/2`
- `Spectre.Directive.Invoker`
  - functions: `call/2`
  - callbacks: `invoke/2`
- `Spectre.Directive.Policy`
  - functions: `call/3`, `call/4`
  - callbacks: `authorize/3`
- `Spectre.Directive.Presenter`
  - functions: `call/2`, `call/3`, `present/2`
  - callbacks: `present/2`
- `Spectre.Directive.Reasoner`
  - functions: `call/2`, `call/3`
  - callbacks: `decide/2`
- `Spectre.Directive.RequestHandler`
  - functions: `call/2`, `call/3`
  - callbacks: `handle_request/2`
- `Spectre.Directive.Snapshot`
  - functions: `active?/1`, `new/2`, `new/3`, `record_turn/5`, `refresh/2`
- `Spectre.Directive.Store`
  - functions: `load/2`, `load/3`, `snapshot/3`, `snapshot/4`
  - callbacks: `load/2`, `snapshot/3`
- `SpectreDirective`
  - functions: `assign/2`, `await/1`, `await/2`, `await_input/1`, `await_input/2`, `cancel/1`, `cancel/2`, `child_spec/1`, `context/1`, `context_map/1`, `control/2`, `create/1`, `inform/2`, `inform/3`, `new/1`, `next/1`, `outcome/1`, `pause/1`, `plan/1`, `protocol/0`, `pulse/1`, `reasoning_input/1`, `reply/2`, `reply/3`, `request/1`, `respond/2`, `respond/3`, `resume/1`, `start_directive/1`, `start_directive/2`, `start_link/0`, `start_link/1`, `start_loop/1`, `start_loop/2`, `start_mission/1`, `start_mission/2`, `state/1`, `stop/1`, `subscribe/1`, `subscribe/2`, `trace/1`
  - macros: `__using__/1`
- `SpectreDirective.AgentDecision`
  - functions: `new/1`
- `SpectreDirective.Context`
  - functions: `to_map/1`
- `SpectreDirective.DSL`
  - macros: `context/1`, `directive/2`, `directive_metadata/1`, `done_when/1`, `expects/1`, `flexibility/1`, `input/1`, `invoke/1`, `kind/1`, `metadata/1`, `mission/1`, `mode/1`, `objective/1`, `on_complete/1`, `policy/1`, `prompt/1`, `purpose/1`, `reason/1`, `risk/1`, `step/1`, `step/2`, `success/1`
- `SpectreDirective.Information`
  - functions: `new/1`, `new/2`
- `SpectreDirective.Integration.GenServer`
  - functions: `handle_info/3`, `start/3`, `start/4`
- `SpectreDirective.Integration.SpectreAgent`
  - functions: `default_reason/3`, `start/2`, `start/3`
- `SpectreDirective.Invocation`
  - functions: `new/1`, `new/2`
- `SpectreDirective.Invocation.Result`
  - functions: `normalize/1`
- `SpectreDirective.Invoker`
  - functions: `call/2`
  - callbacks: `invoke/2`
- `SpectreDirective.Loop.Engine`
  - functions: `assign/2`, `cancel/1`, `cancel/2`, `inform/2`, `inform/3`, `new/1`, `next/1`, `pause/1`, `respond/3`, `resume/1`
- `SpectreDirective.Loop.State`
  - functions: `add_trace/3`, `add_trace/4`, `context/1`, `context/2`, `new/1`, `put_status/2`
- `SpectreDirective.Mission`
  - functions: `new/1`, `new/2`
- `SpectreDirective.MissionBlueprint`
  - functions: `from_mission/1`, `from_mission/2`, `instantiate/1`, `instantiate/2`, `new/1`
- `SpectreDirective.Outcome`
  - functions: `new/2`, `new/3`
- `SpectreDirective.Plan`
  - functions: `add_step/3`, `current_step/1`, `new/1`, `new/2`, `next_pending/1`, `pending_steps/1`, `put_current/2`, `remove_matching/3`, `revise/2`, `revise/3`, `update_step/2`
- `SpectreDirective.PlanPatch`
  - functions: `apply/2`, `new/1`
- `SpectreDirective.Policy`
  - functions: `call/3`, `call/4`
  - callbacks: `authorize/3`
- `SpectreDirective.Protocol`
  - functions: `describe/0`
- `SpectreDirective.Pulse`
  - functions: `from_loop/1`
- `SpectreDirective.Reasoner`
  - functions: `call/2`, `call/3`
  - callbacks: `decide/2`
- `SpectreDirective.Request`
  - functions: `new/2`, `new/3`
- `SpectreDirective.RequestHandler`
  - functions: `call/2`, `call/3`
  - callbacks: `handle_request/2`
- `SpectreDirective.Runtime.Supervisor`
  - functions: `child_spec/1`, `ensure_started/0`, `ensure_started/1`, `start_link/0`, `start_link/1`
- `SpectreDirective.Step`
  - functions: `new/1`, `new/2`
- `SpectreDirective.Trace.Entry`
  - functions: `new/3`, `new/4`
- `SpectreDirective.WorkingContext`
  - functions: `add/2`, `add/3`, `add_many/2`, `add_many/3`, `new/0`, `new/1`, `put_assigns/2`
