defmodule SpectreDirectivePlanningTest do
  use ExUnit.Case

  alias SpectreDirective.Planning.DraftParser

  test "draft parser turns normal planning text into steps" do
    draft = """
    Strategy: observe first, then verify.

    Plan:
    1. Observe signup entry
       kind: observe
       purpose: Understand which signup options exist.
       expects: Visible methods, fields, and blockers.
       capability: observe_page
       flexibility: agentic
       risk: low
       note: Keep the observation short.

    Step: Verify signup result
    Kind: verify
    Purpose: Decide if the signup path satisfies the release check.
    Done: Pass/fail answer with evidence.
    Flexibility: locked
    """

    assert {:ok, plan} = DraftParser.parse(draft)
    assert [observe, verify] = plan.steps

    assert observe.title == "Observe signup entry"
    assert observe.kind == :observe
    assert observe.purpose == "Understand which signup options exist."
    assert observe.expected_output == "Visible methods, fields, and blockers."
    assert observe.required_capability == "observe_page"
    assert observe.flexibility == :agentic
    assert observe.metadata == %{"note" => "Keep the observation short."}

    assert verify.title == "Verify signup result"
    assert verify.kind == :verify
    assert verify.done_condition == "Pass/fail answer with evidence."
    assert verify.flexibility == :locked
  end

  test "draft parser handles several self-generated model-style drafts" do
    drafts = [
      {
        """
        Here is a compact plan.

        ### Step 1: **Observe current signup state**
        **Kind:** observe
        **Purpose:** See what the user can actually do before acting.
        **Expects:** Signup entry points and obvious blockers.

        ### Step 2: **Summarize release risk**
        **Kind:** summarize
        **Purpose:** Explain whether the release check is safe to continue.
        """,
        ["Observe current signup state", "Summarize release risk"],
        [:observe, :summarize]
      },
      {
        """
        Strategy: keep the plan small and evidence-first.

        1) Inspect available account paths
        - kind: investigate
        - purpose: Determine whether email, SSO, or invitation signup is available.
        - capability: observe_page
        - flexibility: guided

        2) Verify the expected post-signup state
        - kind: verify
        - purpose: Confirm the destination matches the success criteria.
        - done: Evidence-backed pass/fail.
        """,
        ["Inspect available account paths", "Verify the expected post-signup state"],
        [:investigate, :verify]
      },
      {
        """
        Plan:

        Step 1 - Ask for missing test account constraints
        kind: ask
        purpose: Avoid using real customer data or unsafe payment details.

        Step 2 - Finish with the safest next action
        kind: finish
        purpose: Return the recommended next move with uncertainty.
        risk: none
        """,
        ["Ask for missing test account constraints", "Finish with the safest next action"],
        [:ask, :finish]
      }
    ]

    for {draft, titles, kinds} <- drafts do
      assert {:ok, plan} = DraftParser.parse(draft)
      assert Enum.map(plan.steps, & &1.title) == titles
      assert Enum.map(plan.steps, & &1.kind) == kinds
    end
  end

  test "draft parser rejects drafts without steps" do
    assert {:error, :no_steps} = DraftParser.parse("Strategy: think carefully.")
  end

  test "draft parser parses one guided step or finish" do
    assert {:ok, step} =
             DraftParser.parse_next_step("""
             Step: Ask for test credentials
             kind: ask
             purpose: Avoid unsafe real account usage.
             done: The credential constraint is known.
             """)

    assert step.title == "Ask for test credentials"
    assert step.kind == :ask
    assert step.done_condition == "The credential constraint is known."

    assert {:ok, step_with_done_when} =
             DraftParser.parse_next_step("""
             Step: Verify signup state
             kind: verify
             purpose: Decide whether signup has enough evidence.
             done_when: The signup state is known.
             """)

    assert step_with_done_when.done_condition == "The signup state is known."

    assert {:finish, "enough steps exist"} =
             DraftParser.parse_next_step("Finish: enough steps exist")
  end

  test "draft parser falls back for unknown enum words without creating atoms" do
    draft = """
    Plan:
    1. Look around
       kind: wildly_custom
       flexibility: improvise
       risk: spicy
    """

    assert {:ok, plan} = DraftParser.parse(draft)
    assert [step] = plan.steps
    assert step.kind == :investigate
    assert step.flexibility == :guided
    assert step.risk == :low
  end
end
