defmodule SpectreDirective.CodexIntegrationTest do
  use ExUnit.Case

  @moduletag :codex
  @run_real_turn System.get_env("SPECTRE_DIRECTIVE_RUN_CODEX_INTEGRATION") in ["1", "true", "yes"]

  test "codex cli is installed and exposes app-server" do
    assert codex = System.find_executable("codex")

    assert {version, 0} = System.cmd(codex, ["--version"], stderr_to_stdout: true)
    assert version =~ "codex"

    assert {help, 0} = System.cmd(codex, ["app-server", "--help"], stderr_to_stdout: true)
    assert help =~ "Usage: codex app-server"
  end

  if @run_real_turn do
    @tag :codex_real_turn
    test "real codex app-server turn completes through SpectreDirective" do
      root = temporary_workspace()
      File.mkdir_p!(root)

      try do
        job = %SpectreDirective.Jobs.CodexAgent{
          prompt:
            "Reply exactly with SPECTRE_DIRECTIVE_CODEX_OK. Do not run commands. Do not edit files.",
          cwd: root,
          timeout_ms: 120_000,
          metadata: %{title: "SpectreDirective Codex Integration Test"}
        }

        assert {:ok, task} = SpectreDirective.submit(job)
        assert {:ok, finished} = SpectreDirective.await(task.id, 130_000)
        assert finished.status == :succeeded
        assert %{status: :completed, session_id: session_id} = finished.result
        assert is_binary(session_id)

        assert {:ok, events} = SpectreDirective.events(task.id)
        assert Enum.any?(events, &(&1.type == :session_started))
        assert Enum.any?(events, &(&1.type == :turn_completed))
      after
        File.rm_rf(root)
      end
    end

    @spec temporary_workspace() :: Path.t()
    defp temporary_workspace do
      Path.join(
        System.tmp_dir!(),
        "spectre-directive-codex-#{System.unique_integer([:positive, :monotonic])}"
      )
    end
  else
    @tag skip: "set SPECTRE_DIRECTIVE_RUN_CODEX_INTEGRATION=1 to run a real Codex turn"
    test "real codex app-server turn completes through SpectreDirective" do
      :ok
    end
  end
end
