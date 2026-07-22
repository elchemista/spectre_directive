defmodule SpectreDirective.Protocol do
  @moduledoc "Provider-neutral description of the mission reasoner contract."

  @doc "Returns JSON-friendly instructions a host may include in an LLM request."
  @spec describe() :: map()
  def describe do
    %{
      version: 1,
      rule: "Return exactly one decision for the current operation.",
      decisions: %{
        invoke: %{
          fields: ["target", "policy"],
          meaning: "Request one trusted host invocation. The host must resolve target references."
        },
        ask: %{
          fields: ["question"],
          meaning: "Request information from the application or user."
        },
        policy: %{
          fields: ["policy", "invocation"],
          meaning: "Request an application policy decision, optionally before an invocation."
        },
        propose_plan: %{
          fields: ["plan"],
          meaning: "Propose initial steps. Guided mode requires confirmation."
        },
        propose_patch: %{
          fields: ["patch", "information"],
          meaning: "Add, insert, replace, remove, skip, or reorder plan steps."
        },
        complete_step: %{
          fields: ["result"],
          meaning: "Record the current step result and continue to the next step."
        },
        complete_mission: %{
          fields: ["result"],
          meaning: "Finish the mission with its final result."
        },
        blocked: %{
          fields: ["reason"],
          meaning: "Explain missing information so the loop can request help."
        }
      },
      invocation_results: %{
        inform: "Add information, then reason again.",
        complete_step: "Add the result, close the current step, and continue.",
        complete_mission: "Finish the mission with a result.",
        propose_patch: "Add information and request a versioned plan change.",
        ask: "Pause for application or user information.",
        error: "Record the invocation error and let the reasoner recover."
      },
      patch_operations: ["add", "insert_after", "remove", "replace", "skip", "reorder"]
    }
  end
end
