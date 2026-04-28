defmodule SpectreDirectiveTest do
  use ExUnit.Case

  alias SpectreDirective.Jobs.{Agent, HostCommand, UserCommand, WorkspaceCommand}

  defmodule FakeAgentAdapter do
    def run(job, context) do
      context.emit.(:agent_message, %{model: job.model, prompt: job.prompt})
      context.emit.(:agent_usage, %{input_tokens: "3", output_tokens: 4, total_tokens: 7})
      context.emit.(:rate_limits, %{limit_id: "test", credits: %{remaining: 42}})
      {:ok, %{reply: "done", role: job.role}}
    end
  end

  defmodule SlowAgentAdapter do
    def run(job, context) do
      context.emit.(:session_started, %{session_id: "slow-session", model: job.model})
      context.emit.(:agent_message, %{message: "thinking about #{job.prompt}", step: :thinking})
      Process.sleep(200)
      {:ok, %{reply: "slow done"}}
    end
  end

  defmodule RaisingAgentAdapter do
    def run(_job, _context), do: raise("adapter exploded")
  end

  defmodule ThrowingAgentAdapter do
    def run(_job, _context), do: throw(:adapter_threw)
  end

  defmodule ExitingAgentAdapter do
    def run(_job, _context), do: exit(:adapter_exited)
  end

  test "AL resolver returns protocol job structs" do
    assert {:ok, %WorkspaceCommand{command: "echo hello", cwd: "demo"}} =
             SpectreDirective.resolve(~s(RUN COMMAND WITH: COMMAND="echo hello" CWD="demo"))

    assert {:ok, %HostCommand{command: "uptime", allow_host_execution: true}} =
             SpectreDirective.resolve(~s(RUN HOST COMMAND WITH: COMMAND="uptime" ALLOW=true))

    assert {:ok, %SpectreDirective.Jobs.CodexAgent{prompt: "fix tests", model: "gpt-test"}} =
             SpectreDirective.resolve(
               ~s(RUN CODEX TASK WITH: PROMPT="fix tests" CWD="/tmp" MODEL="gpt-test")
             )
  end

  test "job protocol describes and validates built-in jobs" do
    job = %WorkspaceCommand{command: "echo ok", cwd: "protocol-test"}

    description = SpectreDirective.describe(job)
    assert description.type == :workspace_command
    assert :workspace in description.isolation_modes
    assert :ok = SpectreDirective.Job.validate(job, %{})

    assert {:error, {:host_execution_not_allowed, %{mode: :host}}} =
             SpectreDirective.Job.validate(%HostCommand{command: "echo unsafe"}, %{})
  end

  test "workspace command runs through manager and tracks events" do
    root =
      Path.join(
        System.tmp_dir!(),
        "spectre-directive-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:spectre_directive, :workspace_root, root)

    try do
      assert {:ok, result} =
               SpectreDirective.run(~s(RUN COMMAND WITH: COMMAND="printf hello" CWD="run-test"))

      assert result.exit_status == 0
      assert result.output =~ "hello"

      [task | _] = SpectreDirective.snapshot().completed
      assert task.status in [:succeeded, :failed]
    after
      File.rm_rf(root)
      Application.delete_env(:spectre_directive, :workspace_root)
    end
  end

  test "workspace command can create directories and list real files" do
    root =
      Path.join(
        System.tmp_dir!(),
        "spectre-directive-fs-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:spectre_directive, :workspace_root, root)

    try do
      assert {:ok, mkdir_result} =
               SpectreDirective.run(
                 ~s(RUN COMMAND WITH: COMMAND="mkdir -p nested && touch nested/alpha.txt nested/beta.txt" CWD="fs-test")
               )

      assert mkdir_result.exit_status == 0
      assert File.dir?(Path.join([root, "fs-test", "nested"]))
      assert File.exists?(Path.join([root, "fs-test", "nested", "alpha.txt"]))
      assert File.exists?(Path.join([root, "fs-test", "nested", "beta.txt"]))

      assert {:ok, ls_result} =
               SpectreDirective.run(~s(RUN COMMAND WITH: COMMAND="ls nested" CWD="fs-test"))

      assert ls_result.exit_status == 0
      assert ls_result.output =~ "alpha.txt"
      assert ls_result.output =~ "beta.txt"
    after
      File.rm_rf(root)
      Application.delete_env(:spectre_directive, :workspace_root)
    end
  end

  test "host command can run real ls when explicitly allowed" do
    root =
      Path.join(
        System.tmp_dir!(),
        "spectre-directive-host-ls-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    File.write!(Path.join(root, "host-visible.txt"), "ok")

    try do
      assert {:ok, result} =
               SpectreDirective.run(%HostCommand{
                 command: "ls #{shell_escape(root)}",
                 allow_host_execution: true
               })

      assert result.exit_status == 0
      assert result.output =~ "host-visible.txt"
    after
      File.rm_rf(root)
    end
  end

  test "host command is blocked unless explicitly allowed" do
    assert {:error, {:host_execution_not_allowed, %{mode: :host}}} =
             SpectreDirective.run(%HostCommand{command: "echo no"}, await_timeout_ms: 500)

    completed =
      SpectreDirective.snapshot().completed
      |> Enum.find(
        &(&1.error == {:host_execution_not_allowed, %{mode: :host, cwd: nil, timeout_ms: 60_000}})
      )

    assert completed.status == :failed
    assert completed.last_event == :failed

    assert {:ok, report} = SpectreDirective.status_text(completed.id)
    assert report =~ "status: failed"
    assert report =~ "Host execution was blocked by policy"

    assert {:ok, result} =
             SpectreDirective.run(%HostCommand{command: "printf yes", allow_host_execution: true})

    assert result.output =~ "yes"
  end

  test "workspace command rejects absolute paths outside workspace root" do
    root =
      Path.join(
        System.tmp_dir!(),
        "spectre-directive-policy-root-#{System.unique_integer([:positive])}"
      )

    outside =
      Path.join(
        System.tmp_dir!(),
        "spectre-directive-policy-outside-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:spectre_directive, :workspace_root, root)

    try do
      assert {:error, {:workspace_escape, escaped, configured_root}} =
               SpectreDirective.run(%WorkspaceCommand{command: "pwd", cwd: outside})

      assert escaped == Path.expand(outside)
      assert configured_root == Path.expand(root)
      refute File.exists?(outside)

      failed =
        SpectreDirective.snapshot().completed
        |> Enum.find(&match?({:workspace_escape, ^escaped, ^configured_root}, &1.error))

      assert failed.status == :failed
      assert failed.last_event == :failed
      assert {:ok, report} = SpectreDirective.status_text(failed.id)
      assert report =~ "status: failed"
      assert report =~ "workspace_escape"
    after
      File.rm_rf(root)
      File.rm_rf(outside)
      Application.delete_env(:spectre_directive, :workspace_root)
    end
  end

  test "workspace validation rejects non-binary cwd values" do
    assert {:error, :invalid_workspace_path} =
             SpectreDirective.run(%WorkspaceCommand{command: "pwd", cwd: {:bad, :path}})

    failed =
      SpectreDirective.snapshot().completed
      |> Enum.find(&(&1.error == :invalid_workspace_path))

    assert failed.status == :failed
    assert SpectreDirective.error_text(failed.error) =~ "Task failed: invalid_workspace_path"
  end

  test "user command validation returns clear errors" do
    assert {:error, {:invalid_job, :missing_user}} =
             SpectreDirective.run(%UserCommand{command: "whoami"}, await_timeout_ms: 500)

    assert SpectreDirective.error_text({:invalid_job, :missing_user}) =~
             "missing_user is missing"

    assert {:error, {:invalid_job, :missing_command}} =
             SpectreDirective.run(%UserCommand{user: "nobody"}, await_timeout_ms: 500)

    assert SpectreDirective.error_text({:invalid_job, :missing_command}) =~
             "missing_command is missing"
  end

  test "user command reports sudo runtime errors when sudo is unavailable" do
    original_path = System.get_env("PATH")
    System.put_env("PATH", "")

    on_exit(fn ->
      if original_path do
        System.put_env("PATH", original_path)
      else
        System.delete_env("PATH")
      end
    end)

    assert {:error, {:runtime_unavailable, :sudo}} =
             SpectreDirective.run(%UserCommand{command: "whoami", user: "nobody"},
               await_timeout_ms: 500
             )

    assert SpectreDirective.error_text({:runtime_unavailable, :sudo}) =~
             "Required runtime is unavailable: sudo"
  end

  test "generic agent job delegates through protocol adapter" do
    job = %Agent{
      prompt: "summarize this",
      model: "small",
      role: "summarizer",
      adapter: FakeAgentAdapter
    }

    assert {:ok, task} = SpectreDirective.submit(job)
    assert {:ok, finished} = SpectreDirective.await(task.id, 1_000)
    assert finished.status == :succeeded
    assert finished.result == %{reply: "done", role: "summarizer"}

    assert {:ok, events} = SpectreDirective.events(task.id)
    assert Enum.any?(events, &(&1.type == :agent_message))
    assert finished.last_event == :succeeded
    assert Enum.any?(events, &(&1.type == :agent_usage))

    snapshot = SpectreDirective.snapshot()
    assert snapshot.agent_totals.total_tokens >= 7
    assert snapshot.rate_limits == %{limit_id: "test", credits: %{remaining: 42}}
  end

  test "running agent status exposes last event, message, timestamp, and session" do
    job = %Agent{
      prompt: "live work",
      model: "small",
      adapter: SlowAgentAdapter
    }

    assert {:ok, task} = SpectreDirective.submit(job)

    assert {:ok, running} =
             wait_until(fn ->
               with {:ok, status} <- SpectreDirective.status(task.id),
                    true <- status.last_event == :agent_message do
                 {:ok, status}
               else
                 _ -> :retry
               end
             end)

    assert running.status == :running
    assert running.session_id == "slow-session"
    assert running.last_message == "thinking about live work"
    assert %DateTime{} = running.last_event_at

    assert {:ok, report} = SpectreDirective.status_text(task.id)
    assert report =~ "status: running"
    assert report =~ "last_event: agent_message"
    assert report =~ "last_message: thinking about live work"
    assert report =~ "session: slow-session"

    assert {:ok, finished} = SpectreDirective.await(task.id, 1_000)
    assert finished.status == :succeeded
  end

  test "text reports summarize snapshot, events, and errors for agents" do
    assert {:ok, result} =
             SpectreDirective.run(%HostCommand{
               command: "printf report",
               allow_host_execution: true
             })

    assert result.output =~ "report"

    report = SpectreDirective.snapshot_text()
    assert report =~ "SpectreDirective task report"
    assert report =~ "completed="
    assert report =~ "Recently completed"

    task =
      SpectreDirective.snapshot().completed
      |> Enum.find(&(&1.status == :succeeded and &1.result == result))

    assert task
    assert {:ok, task_report} = SpectreDirective.status_text(task.id)
    assert task_report =~ "Task #{task.id}"
    assert task_report =~ "status: succeeded"
    assert task_report =~ "recent_events:"

    assert {:ok, events_report} = SpectreDirective.events_text(task.id)
    assert events_report =~ "started:"

    assert SpectreDirective.error_text({:host_execution_not_allowed, %{mode: :host}}) =~
             "Host execution was blocked by policy"
  end

  test "workflow job runs child job structs sequentially" do
    jobs = [
      %WorkspaceCommand{command: "printf one", cwd: "workflow-one"},
      %WorkspaceCommand{command: "printf two", cwd: "workflow-two"}
    ]

    assert {:ok, task} = SpectreDirective.workflow(jobs, await_timeout_ms: 2_000)
    assert {:ok, finished} = SpectreDirective.await(task.id, 2_000)
    assert finished.status == :succeeded
    assert [{:ok, first}, {:ok, second}] = finished.result
    assert first.output =~ "one"
    assert second.output =~ "two"
  end

  test "agent adapter exceptions become failed tasks without crashing manager" do
    job = %Agent{
      prompt: "crash safely",
      adapter: RaisingAgentAdapter
    }

    assert {:error, {:exception, %RuntimeError{}, _stack}} =
             SpectreDirective.run(job, await_timeout_ms: 1_000)

    assert SpectreDirective.snapshot_text() =~ "completed="
  end

  test "agent adapter throws become structured task errors" do
    job = %Agent{
      prompt: "throw safely",
      adapter: ThrowingAgentAdapter
    }

    assert {:error, {:throw, :adapter_threw}} = SpectreDirective.run(job, await_timeout_ms: 1_000)
    assert SpectreDirective.error_text({:throw, :adapter_threw}) =~ "Task threw unexpectedly"
  end

  test "agent adapter exits become structured task errors" do
    job = %Agent{
      prompt: "exit safely",
      adapter: ExitingAgentAdapter
    }

    assert {:error, {:exit, :adapter_exited}} = SpectreDirective.run(job, await_timeout_ms: 1_000)
    assert SpectreDirective.error_text({:exit, :adapter_exited}) =~ "Task exited unexpectedly"
  end

  test "safe runtime boundary normalizes direct exceptions, throws, and exits" do
    assert {:error, {:exception, %RuntimeError{}, _stack}} =
             SpectreDirective.Safe.call(fn -> raise("direct boom") end)

    assert {:error, {:throw, :direct_throw}} =
             SpectreDirective.Safe.call(fn -> throw(:direct_throw) end)

    assert {:error, {:exit, :direct_exit}} =
             SpectreDirective.Safe.call(fn -> exit(:direct_exit) end)
  end

  defp wait_until(fun, attempts \\ 20)
  defp wait_until(_fun, 0), do: {:error, :timeout}

  defp wait_until(fun, attempts) do
    case fun.() do
      {:ok, value} ->
        {:ok, value}

      _ ->
        Process.sleep(20)
        wait_until(fun, attempts - 1)
    end
  end

  defp shell_escape(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end
end
