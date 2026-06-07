defmodule SpectreDirectiveErrorTest do
  use ExUnit.Case

  alias SpectreDirective.Step

  defmodule OneDirective do
    use SpectreDirective

    directive "known" do
      mission("Run known directive")
      context("A test directive.")
      success("It starts.")

      step "Observe" do
        kind(:observe)
        purpose("Observe enough to start.")
      end
    end
  end

  test "start_directive reports modules that are not directive modules" do
    assert {:error, {:not_a_directive_module, String}} =
             SpectreDirective.start_directive(String)
  end

  test "start_directive reports missing authored directive names" do
    assert {:error, {:directive_not_found, OneDirective, "missing"}} =
             SpectreDirective.start_directive(OneDirective, directive: "missing")
  end

  test "mission lookups return not_found for unknown ids" do
    assert {:error, :not_found} = SpectreDirective.pulse("mission_missing")
    assert {:error, :not_found} = SpectreDirective.trace("mission_missing")
    assert {:error, :not_found} = SpectreDirective.control("mission_missing", :pause)
  end

  test "unknown control actions are ignored and traced" do
    assert {:ok, pid} =
             SpectreDirective.start_mission("Handle strange controls",
               steps: [Step.new("Observe", kind: :observe)]
             )

    assert {:ok, pulse} = SpectreDirective.control(pid, {:do_what, :unknown})
    assert pulse.status == :running

    assert {:ok, trace} = SpectreDirective.trace(pid)

    assert Enum.any?(
             trace,
             &(&1.type == :control_ignored and &1.message == "Unknown control action ignored.")
           )
  end

  test "runtime can start and complete without any integration adapters" do
    assert {:ok, pid} =
             SpectreDirective.start_mission("No adapters",
               steps: [
                 Step.new("Observe", kind: :observe, purpose: "Observe without integrations")
               ]
             )

    assert {:ok, pulse} = SpectreDirective.pulse(pid)
    assert pulse.current_understanding =~ "No mission-relevant facts"

    assert {:ok, finished} =
             SpectreDirective.complete_step(pid, %{
               summary: "Observed enough.",
               mission_relevant_facts: ["No external integration was needed."]
             })

    assert finished.status == :finished
  end
end
