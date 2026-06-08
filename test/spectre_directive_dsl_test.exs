defmodule SpectreDirectiveDSLTest do
  use ExUnit.Case
  import ExUnit.CaptureIO

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
        strategy(:qa_flow)
        strategy(:safe_operator)
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

  test "multiple directives keep authored state isolated" do
    defmodule MultiDirective do
      use SpectreDirective

      directive "first" do
        mission("Run first directive.")
        context("First context.")
        success("First success.")

        memory do
          scope(:first_scope)
        end

        capabilities do
          allow([:observe_page, :screenshot])
        end

        strategies do
          strategy(:qa_flow)
        end

        step "First step" do
          kind(:observe)
          purpose("Observe the first directive.")
        end
      end

      directive "second" do
        mission("Run second directive.")
        context("Second context.")
        success("Second success.")
        mode(:strict)

        capabilities do
          require_capability(:inspect_repository)
          deny(:real_payment)
        end

        strategies do
          strategy(:focused_research)
        end

        step "Second step" do
          kind(:investigate)
          purpose("Investigate the second directive.")
        end
      end
    end

    [first, second] = MultiDirective.__spectre_directives__()

    assert first.name == "first"
    assert first.mode == :guided
    assert first.memory.scope == [:first_scope]
    assert first.capability_rules.allowed == [:observe_page, :screenshot]
    assert first.capability_rules.required == []
    assert first.capability_rules.denied == []
    assert first.strategies == [:qa_flow]
    assert Enum.map(first.plan.steps, & &1.title) == ["First step"]

    assert second.name == "second"
    assert second.mode == :strict
    assert second.memory == %{}
    assert second.capability_rules.allowed == []
    assert second.capability_rules.required == [:inspect_repository]
    assert second.capability_rules.denied == [:real_payment]
    assert second.strategies == [:focused_research]
    assert Enum.map(second.plan.steps, & &1.title) == ["Second step"]
  end

  test "step DSL captures optional fields and default values" do
    defmodule RichStepDirective do
      use SpectreDirective

      directive "rich-step" do
        mission("Run rich step directive.")
        context("Capture all step fields.")
        success("The step compiles with structured metadata.")

        step "Inspect signup state" do
          kind(:act)
          flexibility(:agentic)
          purpose("Exercise the rich ADSL step surface.")
          reason("The current state is unknown.")
          prompt("Open the page and inspect visible blockers.")
          expects("A visible state report.")
          done_when("A blocker or success state is identified.")
          risk(:high)
          capability(:observe_page)
          input(%{path: "/signup"})
          metadata(%{area: :signup, owner: "qa"})
        end
      end
    end

    [directive] = RichStepDirective.__spectre_directives__()
    [step] = directive.plan.steps

    assert step.title == "Inspect signup state"
    assert step.kind == :act
    assert step.flexibility == :agentic
    assert step.purpose == "Exercise the rich ADSL step surface."
    assert step.reason == "The current state is unknown."
    assert step.prompt == "Open the page and inspect visible blockers."
    assert step.expected_output == "A visible state report."
    assert step.done_condition == "A blocker or success state is identified."
    assert step.risk == :high
    assert step.required_capability == :observe_page
    assert step.input == %{path: "/signup"}
    assert step.metadata == %{area: :signup, owner: "qa"}
    assert step.source == :authored
    assert step.status == :pending
  end

  test "capability declarations deduplicate list and repeated values" do
    defmodule DedupedCapabilitiesDirective do
      use SpectreDirective

      directive "deduped-capabilities" do
        mission("Run deduped capability directive.")
        context("Capabilities may be declared in lists or one at a time.")
        success("Capability rules are stable.")

        capabilities do
          require_capability([:observe_page, :observe_page])
          require_capability(:inspect_repository)
          allow([:observe_page, :screenshot])
          allow(:screenshot)
          deny([:real_payment, :real_payment])
        end

        step "Observe" do
          purpose("Observe the entry point.")
        end
      end
    end

    [directive] = DedupedCapabilitiesDirective.__spectre_directives__()

    assert directive.capability_rules.required == [:observe_page, :inspect_repository]
    assert directive.capability_rules.allowed == [:observe_page, :screenshot]
    assert directive.capability_rules.denied == [:real_payment]
  end

  test "strategy DSL does not shadow normal Kernel use" do
    defmodule NormalKernelUse do
      defmacro __using__(_opts) do
        quote do
          def injected_from_kernel_use, do: :ok
        end
      end
    end

    defmodule KernelUseDirective do
      use SpectreDirective
      use NormalKernelUse

      directive "kernel-use" do
        mission("Check normal use.")
        context("Kernel use should still work.")
        success("The module compiles.")

        strategies do
          strategy(:qa_flow)
        end

        step "Observe" do
          purpose("Observe the entry point.")
        end
      end
    end

    assert KernelUseDirective.injected_from_kernel_use() == :ok
    assert [%{strategies: [:qa_flow]}] = KernelUseDirective.__spectre_directives__()
  end

  test "use is no longer accepted as strategy syntax" do
    module =
      Module.concat(
        __MODULE__,
        :"RemovedUseStrategyDirective#{System.unique_integer([:positive])}"
      )

    stderr =
      capture_io(:stderr, fn ->
        assert_raise CompileError, fn ->
          Code.compile_quoted(
            quote do
              defmodule unquote(module) do
                use SpectreDirective

                directive "removed-use-strategy" do
                  mission("Check signup.")
                  context("Release check.")
                  success("Signup succeeds.")

                  strategies do
                    use :qa_flow
                  end

                  step "Observe" do
                    purpose("Observe the entry point.")
                  end
                end
              end
            end
          )
        end
      end)

    assert stderr =~ "module :qa_flow is not loaded"
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

  test "directive compilation rejects blank required text" do
    assert_raise ArgumentError,
                 ~r/mission\/1 is required; context\/1 is required; success\/1 is required/,
                 fn ->
                   defmodule BlankRequiredTextDirective do
                     use SpectreDirective

                     directive "blank-required-text" do
                       mission("  ")
                       context("")
                       success("\n")

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

  test "step compilation rejects blank purpose" do
    assert_raise ArgumentError, ~r/purpose\/1 is required/, fn ->
      defmodule BlankStepPurposeDirective do
        use SpectreDirective

        directive "blank-step-purpose" do
          mission("Check signup.")
          context("Release check.")
          success("Signup succeeds.")

          step "Observe" do
            purpose("  ")
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
