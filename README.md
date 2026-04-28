# SpectreDirective

SpectreDirective is an AL-first Elixir library for running isolated commands,
agent turns, and multi-step workflows while tracking task state in memory.

The important design choice is that executable work is represented by job
structs. `SpectreDirective.Job` is a protocol, so future agents or task types
can be added by defining a struct and implementing the protocol. The manager
does not need to know whether a job runs on the host, in a workspace, under a
Linux user, or through Codex.

## What It Owns

- AL fallback parsing for core Directive actions.
- Protocol-based job execution.
- In-memory task lifecycle tracking.
- Task events, progress, last agent message, and session id.
- Human/LLM-readable status and error reports.
- Workspace preparation and command execution.
- Optional Codex app-server execution.
- Optional bridges to `spectre_kinetic` and `spectre_mnemonic`.
- Basic execution policy gates for host commands and workspace paths.

## What It Does Not Own

- Durable memory. Use `spectre_mnemonic` through the optional adapter.
- Tool selection/ranking. Use `spectre_kinetic` through the optional adapter.
- A full distributed scheduler or external issue tracker daemon.
- A hardened security sandbox. The current policy layer is intentionally small
  and must be treated as a guardrail, not a complete isolation boundary.

## Installation

For local development:

```elixir
def deps do
  [
    {:spectre_directive, path: "../spectre_directive"}
  ]
end
```

When published:

```elixir
def deps do
  [
    {:spectre_directive, "~> 0.1.0"}
  ]
end
```

## Quick Start

Run a workspace-isolated command from AL:

```elixir
{:ok, result} =
  SpectreDirective.run(
    ~s(RUN COMMAND WITH: COMMAND="printf hello" CWD="demo")
  )

result.output
```

Submit a task asynchronously:

```elixir
{:ok, task} =
  SpectreDirective.submit(
    ~s(RUN COMMAND WITH: COMMAND="mix test" CWD="repo")
  )

{:ok, status} = SpectreDirective.status(task.id)
{:ok, done} = SpectreDirective.await(task.id, 60_000)
```

Ask for an LLM-readable status report:

```elixir
{:ok, text} = SpectreDirective.status_text(task.id)
IO.puts(text)
```

Example report:

```text
Task task_123
status: running
job: agent
session: slow-session
last_event: agent_message
last_message: thinking about live work
```

## Job Structs

Built-in job structs live under `SpectreDirective.Jobs`:

- `HostCommand` runs directly on the current machine.
- `WorkspaceCommand` runs inside a prepared workspace.
- `UserCommand` runs through `sudo -u`.
- `Agent` delegates to a custom agent adapter.
- `CodexAgent` runs a Codex app-server turn.
- `Workflow` runs child jobs sequentially or in parallel.

Host execution is blocked unless explicitly allowed:

```elixir
alias SpectreDirective.Jobs.HostCommand

job = %HostCommand{
  command: "printf trusted",
  allow_host_execution: true
}

SpectreDirective.run(job)
```

## Isolation And Security Policy

SpectreDirective currently implements a basic execution policy. This is
important: it is not a complete sandbox and should not be described as one.

Implemented today:

- `HostCommand` is denied by default.
- `HostCommand` runs only when explicitly allowed.
- `WorkspaceCommand` prepares and runs inside a configured workspace root.
- Relative workspace paths are resolved under the workspace root.
- Workspace escape attempts are rejected.
- `UserCommand` requires an explicit Linux user and the `sudo` runtime.
- `CodexAgent` requires an explicit `cwd`.

Not implemented yet:

- No central `SpectreDirective.Security.Policy` module.
- No command allowlist or denylist.
- No per-job risk approval workflow.
- No policy caps for max timeout, environment variables, or writable paths.
- No LLM-readable policy report.
- No OS-level sandbox beyond the selected job implementation.

### Controlling Host Execution

Host execution is globally blocked unless you opt in.

Global config:

```elixir
config :spectre_directive,
  allow_host_execution: false
```

Per job:

```elixir
%SpectreDirective.Jobs.HostCommand{
  command: "ls /tmp",
  allow_host_execution: true
}
```

Per call:

```elixir
SpectreDirective.run(
  ~s(RUN HOST COMMAND WITH: COMMAND="ls /tmp"),
  allow_host_execution: true
)
```

AL also supports an explicit `ALLOW=true` slot:

```text
RUN HOST COMMAND WITH: COMMAND="ls /tmp" ALLOW=true
```

If host execution is not allowed, the task fails with:

```elixir
{:host_execution_not_allowed, %{mode: :host, ...}}
```

Use `SpectreDirective.error_text/1` to explain the failure to an LLM or agent:

```elixir
SpectreDirective.error_text({:host_execution_not_allowed, %{mode: :host}})
```

### Controlling Workspace Execution

Workspace jobs run under `:workspace_root`.

```elixir
config :spectre_directive,
  workspace_root: "/tmp/spectre_directive_workspaces"
```

This AL:

```text
RUN COMMAND WITH: COMMAND="mkdir -p out && ls" CWD="task-a"
```

runs under:

```text
/tmp/spectre_directive_workspaces/task-a
```

Absolute or relative paths that resolve outside the configured root are rejected
with a `{:workspace_escape, path, root}` error.

### User Execution

`UserCommand` is available for Linux user isolation:

```elixir
%SpectreDirective.Jobs.UserCommand{
  command: "whoami",
  user: "worker",
  cwd: "/safe/workspace"
}
```

This uses `sudo -n -u worker`. If `sudo` is unavailable, validation returns:

```elixir
{:runtime_unavailable, :sudo}
```

## Extending With A New Job

Define a struct:

```elixir
defmodule MyApp.Jobs.SearchAgent do
  defstruct [:query, :model, timeout_ms: 120_000]
end
```

Implement the protocol:

```elixir
defimpl SpectreDirective.Job, for: MyApp.Jobs.SearchAgent do
  def describe(_job) do
    %{
      type: :search_agent,
      capability: "Searches internal documents.",
      risk: :low,
      required_fields: [:query],
      expected_output: "search results",
      isolation_modes: [:agent]
    }
  end

  def validate(%{query: query}, _context) when is_binary(query) and query != "", do: :ok
  def validate(_job, _context), do: {:error, {:invalid_job, :missing_query}}

  def isolation(job, _context), do: %{mode: :agent, model: job.model}

  def run(job, context) do
    context.emit.(:agent_message, %{message: "searching #{job.query}"})
    {:ok, MyApp.Search.run(job.query)}
  end

  def cancel(_job, _context), do: :ok
end
```

Then submit it:

```elixir
SpectreDirective.submit(%MyApp.Jobs.SearchAgent{query: "deployment notes"})
```

## AL Fallback Resolver

Directive works without `spectre_kinetic`. The built-in resolver supports:

```text
RUN COMMAND WITH: COMMAND="..." CWD="..."
RUN HOST COMMAND WITH: COMMAND="..." ALLOW=true
RUN USER COMMAND WITH: COMMAND="..." USER="worker"
RUN CODEX TASK WITH: PROMPT="..." CWD="..." MODEL="..."
SPAWN AGENT WITH: TASK="..." MODEL="..." ROLE="..."
```

If `:kinetic` is passed, Directive tries `SpectreKinetic.plan/3` at runtime.
There is no compile-time dependency.

## Tracking And Reports

Structured APIs:

```elixir
SpectreDirective.status(task_id)
SpectreDirective.events(task_id)
SpectreDirective.snapshot()
```

LLM-readable APIs:

```elixir
SpectreDirective.status_text(task_id)
SpectreDirective.events_text(task_id)
SpectreDirective.snapshot_text()
SpectreDirective.error_text(reason)
```

Tracked task fields include:

- `status`
- `progress`
- `result`
- `error`
- `last_event`
- `last_message`
- `last_event_at`
- `session_id`
- recent events

These fields let an agent ask what is running and understand what a subagent is
doing without decoding raw structs.

## Workflows

Run a sequence of jobs:

```elixir
alias SpectreDirective.Jobs.WorkspaceCommand

jobs = [
  %WorkspaceCommand{command: "mix deps.get", cwd: "repo"},
  %WorkspaceCommand{command: "mix test", cwd: "repo"}
]

{:ok, task} = SpectreDirective.workflow(jobs)
{:ok, done} = SpectreDirective.await(task.id)
```

`SpectreDirective.Jobs.Workflow` also supports `mode: :parallel`.

## Optional Integrations

### SpectreKinetic

Pass a Kinetic runtime or server target:

```elixir
SpectreDirective.submit(al_text, kinetic: kinetic_runtime)
```

Directive will ask Kinetic to plan the AL, then map the planned action back to
a Directive job.

### SpectreMnemonic

If `SpectreMnemonic` is available, task events are sent as memory signals.
You can also configure a custom memory adapter:

```elixir
config :spectre_directive, :memory_adapter, MyApp.DirectiveMemory
```

The adapter should implement `record(event, opts)`.

## Codex

`SpectreDirective.Jobs.CodexAgent` uses a minimal Codex app-server client by
default:

```elixir
%SpectreDirective.Jobs.CodexAgent{
  prompt: "Fix the failing tests",
  cwd: "/path/to/workspace",
  model: "gpt-5.3-codex"
}
```

You can replace the client:

```elixir
config :spectre_directive, :codex_client, MyApp.CodexClient
```

The client should implement `run(job, context)`.

The real Codex app-server integration test is opt-in because it launches Codex
and may use your configured account/model:

```bash
SPECTRE_DIRECTIVE_RUN_CODEX_INTEGRATION=1 mix test test/codex_integration_test.exs --trace
```

## Project Layout

```text
lib/spectre_directive.ex              Public facade
lib/spectre_directive/job.ex          Job protocol
lib/spectre_directive/jobs/           Job structs
lib/spectre_directive/job/impl/       Protocol implementations
lib/spectre_directive/core/           Task, event, presenter
lib/spectre_directive/runtime/        Manager, command, workspace
lib/spectre_directive/integrations/   Optional Spectre adapters
lib/spectre_directive/workflow/       Workflow file cache
lib/spectre_directive/codex/          Codex app-server client
```

## Development

```bash
mix format
mix test
mix compile --warnings-as-errors
```
