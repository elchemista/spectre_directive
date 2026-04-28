defmodule SpectreDirective.CommandMatrixTest do
  use ExUnit.Case

  alias SpectreDirective.AL
  alias SpectreDirective.Jobs.{Agent, CodexAgent, HostCommand, UserCommand, WorkspaceCommand}

  @workspace_success_commands [
    {"printf plain text", "printf alpha", ["alpha"]},
    {"echo newline text", "echo beta", ["beta"]},
    {"multiple output lines", "printf 'one\\ntwo\\nthree\\n'", ["one", "two", "three"]},
    {"quoted spaces", ~s(printf "hello world"), ["hello world"]},
    {"single quotes inside shell", ~s(printf 'single quoted'), ["single quoted"]},
    {"double quotes inside shell", ~s(printf "double quoted"), ["double quoted"]},
    {"command chaining", "printf first && printf second", ["firstsecond"]},
    {"shell arithmetic", "printf $((21 + 21))", ["42"]},
    {"environment expansion", "printf \"$SPECTRE_VALUE\"", ["matrix-env"]},
    {"stderr is captured", "printf err >&2", ["err"]},
    {"true exits cleanly", "true && printf clean", ["clean"]},
    {"pwd basename can be inspected", "basename \"$PWD\" | grep '^case-' && printf ok", ["ok"]},
    {"mkdir creates a directory", "mkdir made && test -d made && printf made", ["made"]},
    {"touch creates a file", "touch file.txt && test -f file.txt && printf file", ["file"]},
    {"cat reads a file", "printf content > data.txt && cat data.txt", ["content"]},
    {"wc counts bytes", "printf 12345 > bytes.txt && wc -c < bytes.txt", ["5"]},
    {"ls sees created files", "touch a.txt b.txt && ls | sort", ["a.txt", "b.txt"]},
    {"nested directories work",
     "mkdir -p nested/deep && touch nested/deep/item && find nested -type f",
     ["nested/deep/item"]},
    {"grep finds a line", "printf 'red\\nblue\\n' | grep blue", ["blue"]},
    {"grep invert match", "printf 'red\\nblue\\n' | grep -v red", ["blue"]},
    {"tr uppercases data", "printf abc | tr a-z A-Z", ["ABC"]},
    {"cut by character", "printf hello | cut -c1-2", ["he"]},
    {"cut by delimiter", "printf left:right | cut -d: -f2", ["right"]},
    {"sort orders lines", "printf 'c\\na\\nb\\n' | sort", ["a", "b", "c"]},
    {"uniq collapses duplicates", "printf 'x\\nx\\ny\\n' | uniq", ["x", "y"]},
    {"head selects first line", "printf 'top\\nnext\\n' | head -n 1", ["top"]},
    {"tail selects last line", "printf 'top\\nlast\\n' | tail -n 1", ["last"]},
    {"test command succeeds", "test 4 -gt 3 && printf greater", ["greater"]},
    {"subshell succeeds", "(printf nested)", ["nested"]},
    {"bash loop prints values", "for n in 1 2 3; do printf \"$n\"; done", ["123"]},
    {"read from here string", "read value <<< hello && printf \"$value\"", ["hello"]},
    {"temporary variable", "VALUE=temp; printf \"$VALUE\"", ["temp"]},
    {"append to file", "printf a > out.txt && printf b >> out.txt && cat out.txt", ["ab"]},
    {"overwrite file", "printf old > out.txt && printf new > out.txt && cat out.txt", ["new"]},
    {"remove file", "touch gone.txt && rm gone.txt && test ! -e gone.txt && printf removed",
     ["removed"]},
    {"copy file", "printf source > src.txt && cp src.txt dst.txt && cat dst.txt", ["source"]},
    {"move file", "printf source > src.txt && mv src.txt dst.txt && cat dst.txt", ["source"]},
    {"sleep briefly then output", "sleep 0.02 && printf awake", ["awake"]},
    {"empty command still exits", " : && printf colon", ["colon"]},
    {"unicode free binary output", "printf ascii-only-output", ["ascii-only-output"]}
  ]

  @workspace_failure_commands [
    {"false exits one", "false", 1, []},
    {"explicit exit two", "exit 2", 2, []},
    {"explicit exit three with stderr", "printf err >&2; exit 3", 3, ["err"]},
    {"explicit exit four with stdout", "printf before; exit 4", 4, ["before"]},
    {"missing command exits 127", "spectre_command_that_should_not_exist", 127,
     ["spectre_command_that_should_not_exist"]},
    {"missing ls target", "ls no_such_file", nil, ["no_such_file"]},
    {"missing cat target", "cat no_such_file", nil, ["no_such_file"]},
    {"missing grep target", "grep needle no_such_file", nil, ["no_such_file"]},
    {"test missing file", "test -f no_such_file", 1, []},
    {"directory test fails", "test -d no_such_dir", 1, []},
    {"mkdir missing parent fails", "mkdir missing/child", nil, ["missing/child"]},
    {"rmdir missing fails", "rmdir missing", nil, []},
    {"rm missing fails", "rm missing", nil, []},
    {"cp missing fails", "cp missing target", nil, []},
    {"mv missing fails", "mv missing target", nil, []},
    {"chmod missing fails", "chmod 600 missing", nil, []},
    {"mkdir over file fails", "printf data > taken && mkdir taken", nil, []},
    {"grep no match exits one", "printf data | grep nope", 1, []},
    {"bad cd fails", "cd no_such_dir", nil, []},
    {"bad numeric test fails", "test x -eq 1", nil, []},
    {"explicit exit five", "sh -c 'exit 5'", 5, []},
    {"explicit exit six", "bash -lc 'exit 6'", 6, []},
    {"pipeline failure with pipefail", "set -o pipefail; false | cat", 1, []},
    {"subshell failure", "(exit 7)", 7, []},
    {"conditional failure", "[ -f nope ]", 1, []}
  ]

  @workspace_timeout_commands [
    {"sleep is interrupted", "sleep 0.2", 40, []},
    {"partial stdout before timeout", "printf before; sleep 0.2", 40, ["before"]},
    {"late output is not required", "sleep 0.2; printf after", 40, []},
    {"read waits too long", "read value", 40, []},
    {"loop waits too long", "while true; do sleep 0.1; done", 50, []},
    {"slow compound command", "printf start; sleep 0.2; printf end", 50, ["start"]},
    {"longer configured timeout still fires", "sleep 0.25", 60, []},
    {"stderr before timeout", "printf waiting >&2; sleep 0.2", 50, ["waiting"]}
  ]

  @host_success_commands [
    {"host printf", "printf host-alpha", ["host-alpha"]},
    {"host echo", "echo host-beta", ["host-beta"]},
    {"host arithmetic", "printf $((6 * 7))", ["42"]},
    {"host stderr capture", "printf host-error >&2", ["host-error"]},
    {"host true command", "true && printf host-clean", ["host-clean"]},
    {"host pipeline", "printf host | tr a-z A-Z", ["HOST"]},
    {"host pwd", "pwd", [Path.basename(File.cwd!())]},
    {"host shell variable", "VALUE=host-var; printf \"$VALUE\"", ["host-var"]},
    {"host short sleep", "sleep 0.02 && printf host-awake", ["host-awake"]},
    {"host file listing", "touch host-matrix-file && ls host-matrix-file && rm host-matrix-file",
     ["host-matrix-file"]}
  ]

  @resolver_cases [
    {"workspace command quoted", ~s(RUN COMMAND WITH: COMMAND="printf hi" CWD="alpha"),
     WorkspaceCommand, [command: "printf hi", cwd: "alpha"]},
    {"workspace command bare timeout", ~s(RUN COMMAND WITH: COMMAND=ls TIMEOUT_MS=123),
     WorkspaceCommand, [command: "ls", timeout_ms: 123]},
    {"workspace invalid timeout falls back", ~s(RUN COMMAND WITH: COMMAND=ls TIMEOUT_MS=nope),
     WorkspaceCommand, [timeout_ms: 60_000]},
    {"host allow true", ~s(RUN HOST COMMAND WITH: COMMAND="printf hi" ALLOW=true), HostCommand,
     [allow_host_execution: true]},
    {"host allow yes", ~s(RUN HOST COMMAND WITH: COMMAND="printf hi" ALLOW=yes), HostCommand,
     [allow_host_execution: true]},
    {"host allow one", ~s(RUN HOST COMMAND WITH: COMMAND="printf hi" ALLOW=1), HostCommand,
     [allow_host_execution: true]},
    {"host allow false", ~s(RUN HOST COMMAND WITH: COMMAND="printf hi" ALLOW=false), HostCommand,
     [allow_host_execution: false]},
    {"host allow no", ~s(RUN HOST COMMAND WITH: COMMAND="printf hi" ALLOW=no), HostCommand,
     [allow_host_execution: false]},
    {"host allow zero", ~s(RUN HOST COMMAND WITH: COMMAND="printf hi" ALLOW=0), HostCommand,
     [allow_host_execution: false]},
    {"host cwd slot", ~s(RUN HOST COMMAND WITH: COMMAND=pwd CWD="/tmp"), HostCommand,
     [cwd: "/tmp"]},
    {"user command", ~s(RUN USER COMMAND WITH: COMMAND=whoami USER=nobody), UserCommand,
     [command: "whoami", user: "nobody"]},
    {"user group", ~s(RUN USER COMMAND WITH: COMMAND=id USER=nobody GROUP=nogroup), UserCommand,
     [group: "nogroup"]},
    {"user cwd", ~s(RUN USER COMMAND WITH: COMMAND=pwd USER=nobody CWD="/tmp"), UserCommand,
     [cwd: "/tmp"]},
    {"codex prompt", ~s(RUN CODEX TASK WITH: PROMPT="fix bug" MODEL=gpt-test), CodexAgent,
     [prompt: "fix bug", model: "gpt-test"]},
    {"codex task alias", ~s(RUN CODEX TASK WITH: TASK="fix task"), CodexAgent,
     [prompt: "fix task"]},
    {"codex timeout", ~s(RUN CODEX TASK WITH: PROMPT="fix" TIMEOUT_MS=321), CodexAgent,
     [timeout_ms: 321]},
    {"agent task alias", ~s(SPAWN AGENT WITH: TASK="summarize" ROLE=reader MODEL=small), Agent,
     [prompt: "summarize", role: "reader", model: "small"]},
    {"agent prompt", ~s(SPAWN AGENT WITH: PROMPT="write report"), Agent,
     [prompt: "write report"]},
    {"agent timeout", ~s(SPAWN AGENT WITH: TASK=go TIMEOUT_MS=222), Agent, [timeout_ms: 222]},
    {"workspace option host allow stays workspace", ~s(RUN COMMAND WITH: COMMAND=echo),
     WorkspaceCommand, [command: "echo"]}
  ]

  for {name, command, expected_fragments} <- @workspace_success_commands do
    test "workspace command succeeds: #{name}" do
      command = unquote(command)
      expected_fragments = unquote(Macro.escape(expected_fragments))

      with_workspace_root(unquote(name), fn _root ->
        job = %WorkspaceCommand{
          command: command,
          cwd: unique_case_dir(unquote(name)),
          env: %{"SPECTRE_VALUE" => "matrix-env"},
          timeout_ms: 1_000
        }

        assert {:ok, result} = SpectreDirective.run(job, await_timeout_ms: 2_000)
        assert result.exit_status == 0

        for fragment <- expected_fragments do
          assert result.output =~ fragment
        end
      end)
    end
  end

  for {name, command, expected_status, expected_fragments} <- @workspace_failure_commands do
    test "workspace command fails clearly: #{name}" do
      command = unquote(command)
      expected_status = unquote(expected_status)
      expected_fragments = unquote(Macro.escape(expected_fragments))

      with_workspace_root(unquote(name), fn _root ->
        job = %WorkspaceCommand{
          command: command,
          cwd: unique_case_dir(unquote(name)),
          timeout_ms: 1_000
        }

        assert {:error, {:exit_status, status, result}} =
                 SpectreDirective.run(job, await_timeout_ms: 2_000)

        assert status > 0
        assert result.exit_status == status

        if expected_status do
          assert status == expected_status
        end

        for fragment <- expected_fragments do
          assert result.output =~ fragment
        end

        assert SpectreDirective.error_text({:exit_status, status, result}) =~
                 "Command exited with status #{status}"
      end)
    end
  end

  for {name, command, timeout_ms, expected_fragments} <- @workspace_timeout_commands do
    test "workspace command timeout is tracked: #{name}" do
      command = unquote(command)
      timeout_ms = unquote(timeout_ms)
      expected_fragments = unquote(Macro.escape(expected_fragments))

      with_workspace_root(unquote(name), fn _root ->
        job = %WorkspaceCommand{
          command: command,
          cwd: unique_case_dir(unquote(name)),
          timeout_ms: timeout_ms
        }

        assert {:error, {:timeout, ^timeout_ms, details}} =
                 SpectreDirective.run(job, await_timeout_ms: 1_000)

        for fragment <- expected_fragments do
          assert details.output =~ fragment
        end

        assert SpectreDirective.error_text({:timeout, timeout_ms, details}) =~
                 "Task timed out after #{timeout_ms}ms"
      end)
    end
  end

  for {name, command, expected_fragments} <- @host_success_commands do
    test "allowed host command succeeds: #{name}" do
      command = unquote(command)
      expected_fragments = unquote(Macro.escape(expected_fragments))

      assert {:ok, result} =
               SpectreDirective.run(%HostCommand{
                 command: command,
                 allow_host_execution: true,
                 timeout_ms: 1_000
               })

      assert result.exit_status == 0

      for fragment <- expected_fragments do
        assert result.output =~ fragment
      end
    after
      File.rm("host-matrix-file")
    end
  end

  for {name, al, module, fields} <- @resolver_cases do
    test "AL resolver matrix: #{name}" do
      assert {:ok, job} = SpectreDirective.resolve(unquote(al))
      assert match?(%unquote(module){}, job)

      for {field, value} <- unquote(Macro.escape(fields)) do
        assert Map.fetch!(job, field) == value
      end
    end
  end

  test "AL resolver returns unsupported text as structured error" do
    assert {:error, {:unsupported_al, "MAKE COFFEE"}} = SpectreDirective.resolve("MAKE COFFEE")

    assert SpectreDirective.error_text({:unsupported_al, "MAKE COFFEE"}) =~
             "does not know how to resolve this AL instruction"
  end

  test "AL resolver returns unsupported non-string input as structured error" do
    assert {:error, {:unsupported_input, 123}} = SpectreDirective.resolve(123)
    assert SpectreDirective.error_text({:unsupported_input, 123}) =~ "unsupported_input"
  end

  test "workspace validation rejects missing command before shell starts" do
    assert {:error, {:invalid_job, :missing_command}} =
             SpectreDirective.run(%WorkspaceCommand{}, await_timeout_ms: 500)

    assert SpectreDirective.error_text({:invalid_job, :missing_command}) =~
             "missing_command is missing"
  end

  test "host validation rejects missing command before policy checks" do
    assert {:error, {:invalid_job, :missing_command}} =
             SpectreDirective.run(%HostCommand{allow_host_execution: true}, await_timeout_ms: 500)
  end

  test "workspace command with nil cwd receives a generated workspace" do
    with_workspace_root("nil cwd", fn root ->
      assert {:ok, result} =
               SpectreDirective.run(%WorkspaceCommand{
                 command: "pwd",
                 cwd: nil,
                 timeout_ms: 1_000
               })

      assert String.starts_with?(String.trim(result.output), root)
    end)
  end

  test "workspace command with empty cwd receives a generated workspace" do
    with_workspace_root("empty cwd", fn root ->
      assert {:ok, result} =
               SpectreDirective.run(%WorkspaceCommand{command: "pwd", cwd: "", timeout_ms: 1_000})

      assert String.starts_with?(String.trim(result.output), root)
    end)
  end

  test "workspace command can use explicit job workspace root without app env" do
    root = temporary_root("explicit root")

    try do
      assert {:ok, result} =
               SpectreDirective.run(%WorkspaceCommand{
                 command: "printf explicit",
                 cwd: "job-root",
                 workspace_root: root,
                 timeout_ms: 1_000
               })

      assert result.output =~ "explicit"
      assert File.dir?(Path.join(root, "job-root"))
    after
      File.rm_rf(root)
    end
  end

  test "workspace command reports mkdir errors when root is a file" do
    root = temporary_root("root file")
    File.rm_rf!(root)
    File.write!(root, "not a dir")

    try do
      assert {:error, {:mkdir_failed, ^root, :enotdir}} =
               SpectreDirective.run(%WorkspaceCommand{
                 command: "printf nope",
                 cwd: "child",
                 workspace_root: root
               })
    after
      File.rm(root)
    end
  end

  test "host command can be allowed by call context" do
    assert {:ok, result} =
             SpectreDirective.run(%HostCommand{command: "printf context-allowed"},
               allow_host_execution: true
             )

    assert result.output =~ "context-allowed"
  end

  test "host command can be allowed by application config" do
    old = Application.get_env(:spectre_directive, :allow_host_execution)
    Application.put_env(:spectre_directive, :allow_host_execution, true)

    try do
      assert {:ok, result} = SpectreDirective.run(%HostCommand{command: "printf app-allowed"})
      assert result.output =~ "app-allowed"
    after
      restore_env(:allow_host_execution, old)
    end
  end

  test "host command blocked error is agent-readable" do
    assert {:error, reason} = SpectreDirective.run(%HostCommand{command: "printf blocked"})
    assert SpectreDirective.error_text(reason) =~ "Host execution was blocked by policy"
  end

  test "command failure appears in status text" do
    with_workspace_root("failure status", fn _root ->
      assert {:ok, task} =
               SpectreDirective.submit(%WorkspaceCommand{
                 command: "printf fail; exit 9",
                 cwd: unique_case_dir("failure status")
               })

      assert {:ok, finished} = SpectreDirective.await(task.id, 1_000)
      assert finished.status == :failed
      assert finished.last_event == :failed

      assert {:ok, report} = SpectreDirective.status_text(task.id)
      assert report =~ "status: failed"
      assert report =~ "Command exited with status 9"
    end)
  end

  test "command timeout appears in event text" do
    with_workspace_root("timeout events", fn _root ->
      assert {:ok, task} =
               SpectreDirective.submit(%WorkspaceCommand{
                 command: "sleep 0.2",
                 cwd: unique_case_dir("timeout events"),
                 timeout_ms: 40
               })

      assert {:ok, finished} = SpectreDirective.await(task.id, 1_000)
      assert finished.status == :failed
      assert {:ok, events} = SpectreDirective.events_text(task.id)
      assert events =~ "command_timeout"
      assert events =~ "failed"
    end)
  end

  test "parse slots keeps quoted spaces intact" do
    assert %{"COMMAND" => "printf hello world", "CWD" => "space dir"} =
             AL.parse_slots(~s(COMMAND="printf hello world" CWD="space dir"))
  end

  test "parse slots handles bare values" do
    assert %{"COMMAND" => "ls", "TIMEOUT_MS" => "500"} =
             AL.parse_slots("COMMAND=ls TIMEOUT_MS=500")
  end

  @spec with_workspace_root(binary(), (binary() -> term())) :: term()
  defp with_workspace_root(name, fun) do
    root = temporary_root(name)
    old = Application.get_env(:spectre_directive, :workspace_root)
    Application.put_env(:spectre_directive, :workspace_root, root)

    try do
      fun.(root)
    after
      File.rm_rf(root)
      restore_env(:workspace_root, old)
    end
  end

  @spec temporary_root(binary()) :: Path.t()
  defp temporary_root(name) do
    Path.join([
      System.tmp_dir!(),
      "spectre-directive-matrix",
      "#{safe_name(name)}-#{System.unique_integer([:positive, :monotonic])}"
    ])
  end

  @spec unique_case_dir(binary()) :: binary()
  defp unique_case_dir(name) do
    "case-#{safe_name(name)}-#{System.unique_integer([:positive, :monotonic])}"
  end

  @spec safe_name(binary()) :: binary()
  defp safe_name(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  @spec restore_env(atom(), term()) :: :ok
  defp restore_env(key, nil), do: Application.delete_env(:spectre_directive, key)
  defp restore_env(key, value), do: Application.put_env(:spectre_directive, key, value)
end
