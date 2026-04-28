defmodule SpectreDirective.WorkflowStoreTest do
  use ExUnit.Case

  alias SpectreDirective.Workflow

  test "workflow store keeps last known good config after bad reload" do
    path =
      Path.join(
        System.tmp_dir!(),
        "spectre-directive-workflow-#{System.unique_integer([:positive])}.md"
      )

    original_path = Workflow.workflow_file_path()

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_path)
      File.rm(path)
    end)

    File.write!(path, "---\nmax_concurrent: 2\n---\nPrompt")
    Workflow.set_workflow_file_path(path)
    assert :ok = SpectreDirective.WorkflowStore.force_reload()
    assert {:ok, %{config: %{"max_concurrent" => 2}, prompt: "Prompt"}} = Workflow.current()

    File.write!(path, "---\nthis is not supported\n---\nBroken")
    assert {:error, _reason} = SpectreDirective.WorkflowStore.force_reload()
    assert {:ok, %{config: %{"max_concurrent" => 2}, prompt: "Prompt"}} = Workflow.current()
  end
end
