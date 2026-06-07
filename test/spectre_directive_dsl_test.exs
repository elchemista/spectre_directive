defmodule SpectreDirectiveDSLTest do
  use ExUnit.Case

  defmodule SignupDirective do
    use SpectreDirective

    directive "signup-check" do
      mission("Make sure a new user can finish sign up")
      context("This is a release check.")
      success("A test user reaches a valid post-signup state.")
      mode(:guided)

      memory do
        scope({:app, :signup})
        remember(:observations)
        remember(:corrections)
      end

      capabilities do
        require_capability(:observe_current_state)
        allow(:form_fill)
        deny(:real_payment)
      end

      strategies do
        use :qa_flow
        use :safe_operator
      end

      alignment do
        check(:mission_relevance)
        check(:risk, pause_before: "external or destructive actions")
      end

      corrections do
        on(:misaligned, do: :skip_step)
        on(:complete_enough, do: :finish_early)
      end

      step "Observe signup entry" do
        kind(:observe)
        flexibility(:guided)
        purpose("Understand the real signup options before acting")
        prompt("Open the signup page and describe available signup methods.")
        expects("Visible signup methods and required fields.")
      end
    end
  end

  test "use SpectreDirective compiles authored directives" do
    [directive] = SignupDirective.__spectre_directives__()

    assert directive.name == "signup-check"
    assert directive.mission.goal == "Make sure a new user can finish sign up"
    assert directive.mission.context == "This is a release check."
    assert directive.mission.success_criteria == "A test user reaches a valid post-signup state."
    assert directive.mode == :guided
    assert directive.memory.scope == [{:app, :signup}]
    assert directive.memory.remember == [:observations, :corrections]
    assert directive.capability_rules.required == [:observe_current_state]
    assert directive.capability_rules.allowed == [:form_fill]
    assert directive.capability_rules.denied == [:real_payment]
    assert directive.strategies == [:qa_flow, :safe_operator]
    assert {:mission_relevance, []} in directive.alignment_rules
    assert {:misaligned, [do: :skip_step]} in directive.correction_rules

    assert [step] = directive.plan.steps
    assert step.title == "Observe signup entry"
    assert step.kind == :observe
    assert step.purpose == "Understand the real signup options before acting"
    assert step.expected_output == "Visible signup methods and required fields."
  end

  test "directive can be fetched by name" do
    assert %SpectreDirective.MissionBlueprint{name: "signup-check"} =
             SignupDirective.__spectre_directive__("signup-check")
  end

  test "directive compilation requires mission text" do
    assert_raise ArgumentError, ~r/mission\/1 is required/, fn ->
      defmodule MissingMissionDirective do
        use SpectreDirective

        directive "missing-mission" do
          context("Release check.")
          success("Signup succeeds.")

          step "Observe" do
            purpose("Observe the entry point.")
          end
        end
      end
    end
  end

  test "directive compilation requires context and success text" do
    assert_raise ArgumentError, ~r/context\/1 is required; success\/1 is required/, fn ->
      defmodule MissingContextSuccessDirective do
        use SpectreDirective

        directive "missing-context-success" do
          mission("Check signup.")

          step "Observe" do
            purpose("Observe the entry point.")
          end
        end
      end
    end
  end

  test "directive compilation requires at least one step" do
    assert_raise ArgumentError, ~r/at least one step\/2 block is required/, fn ->
      defmodule MissingStepsDirective do
        use SpectreDirective

        directive "missing-steps" do
          mission("Check signup.")
          context("Release check.")
          success("Signup succeeds.")
        end
      end
    end
  end

  test "step compilation requires purpose" do
    assert_raise ArgumentError, ~r/purpose\/1 is required/, fn ->
      defmodule MissingStepPurposeDirective do
        use SpectreDirective

        directive "missing-step-purpose" do
          mission("Check signup.")
          context("Release check.")
          success("Signup succeeds.")

          step "Observe" do
            kind(:observe)
          end
        end
      end
    end
  end

  test "step compilation rejects unknown enum values" do
    assert_raise ArgumentError, ~r/kind\/1 must be one of/, fn ->
      defmodule InvalidKindDirective do
        use SpectreDirective

        directive "invalid-kind" do
          mission("Check signup.")
          context("Release check.")
          success("Signup succeeds.")

          step "Observe" do
            kind(:teleport)
            purpose("Observe the entry point.")
          end
        end
      end
    end

    assert_raise ArgumentError, ~r/flexibility\/1 must be one of/, fn ->
      defmodule InvalidFlexibilityDirective do
        use SpectreDirective

        directive "invalid-flexibility" do
          mission("Check signup.")
          context("Release check.")
          success("Signup succeeds.")

          step "Observe" do
            flexibility(:chaotic)
            purpose("Observe the entry point.")
          end
        end
      end
    end

    assert_raise ArgumentError, ~r/risk\/1 must be one of/, fn ->
      defmodule InvalidRiskDirective do
        use SpectreDirective

        directive "invalid-risk" do
          mission("Check signup.")
          context("Release check.")
          success("Signup succeeds.")

          step "Observe" do
            risk(:cosmic)
            purpose("Observe the entry point.")
          end
        end
      end
    end
  end
end
