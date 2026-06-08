defmodule SpectreDirective.Planner do
  @moduledoc """
  Text-first initial planning boundary for agents.

  Agents are usually better at writing a clear plan in normal language than at
  producing perfect maps. For that reason the planner boundary asks a host
  application for a textual planning draft, then parses that draft into
  `SpectreDirective.Step` structs.

  The simplest host integration is
  `SpectreDirective.create(%{model: &MyApp.Model.complete/1})`. That function
  receives a prompt and returns text.

  A planner adapter module is the richer option. It receives a
  `SpectreDirective.Planning.Request` containing both structured mission state
  and a ready-to-send English prompt.

      defmodule MyApp.DirectivePlanner do
        @behaviour SpectreDirective.Planner

        @impl SpectreDirective.Planner
        def draft_plan(request, _opts) do
          MyApp.ModelClient.complete(request.prompt)
        end
      end

      SpectreDirective.create(%{
        mission: "Check signup",
        planner: MyApp.DirectivePlanner
      })

  Planning can run in two modes:

    * `planning_mode: :draft` asks for the whole initial plan in one call.
    * `planning_mode: :guided` is manual and OTP-driven; the runtime waits for
      explicit proposal, accept, reject, and finish calls.

  The model may answer in a small text shape:

      Strategy: inspect the real signup path before acting.

      Plan:
      1. Observe signup entry
         kind: observe
         purpose: Understand the available signup options.
         expects: Visible methods, required fields, and blockers.
         capability: observe_page

      2. Verify signup result
         kind: verify
         purpose: Decide whether the mission succeeded.

  If the planner fails or the draft cannot be parsed into at least one step,
  SpectreDirective keeps the existing authored or emergent plan and records the
  fallback in the mission trace.
  """

  alias SpectreDirective.CapabilitySnapshot
  alias SpectreDirective.Knowledge
  alias SpectreDirective.MissionBlueprint
  alias SpectreDirective.Plan
  alias SpectreDirective.Planning.DraftParser
  alias SpectreDirective.Planning.Request
  alias SpectreDirective.Planning.TextProvider

  @type draft_result :: term()

  @type build_result :: %{
          required(:plan) => Plan.t(),
          required(:trace) => [{atom(), binary(), term()}]
        }

  @callback draft_plan(Request.t(), keyword()) :: draft_result()

  @doc """
  Builds the initial plan with an optional text-first host planner.
  """
  @spec build_initial_plan(
          MissionBlueprint.t(),
          Knowledge.t(),
          CapabilitySnapshot.t(),
          keyword()
        ) :: build_result()
  def build_initial_plan(
        %MissionBlueprint{} = blueprint,
        %Knowledge{} = knowledge,
        %CapabilitySnapshot{} = capabilities,
        opts
      )
      when is_list(opts) do
    opts
    |> TextProvider.from_opts()
    |> build_with_provider(blueprint, knowledge, capabilities, opts)
  end

  @spec build_with_provider(
          TextProvider.provider() | nil | :none | term(),
          MissionBlueprint.t(),
          Knowledge.t(),
          CapabilitySnapshot.t(),
          keyword()
        ) :: build_result()
  defp build_with_provider(nil, blueprint, _knowledge, _capabilities, _opts) do
    %{plan: blueprint.plan, trace: []}
  end

  defp build_with_provider(:none, blueprint, _knowledge, _capabilities, _opts) do
    %{plan: blueprint.plan, trace: []}
  end

  defp build_with_provider(provider, blueprint, knowledge, capabilities, opts) do
    case planning_mode(opts) do
      :guided -> manual_guided(blueprint)
      :draft -> build_draft(provider, blueprint, knowledge, capabilities, opts)
      mode -> fallback(blueprint, :invalid_planning_mode, mode)
    end
  end

  @spec planning_mode(keyword()) :: atom()
  defp planning_mode(opts), do: Keyword.get(opts, :planning_mode, :draft)

  @spec build_draft(
          TextProvider.provider(),
          MissionBlueprint.t(),
          Knowledge.t(),
          CapabilitySnapshot.t(),
          keyword()
        ) :: build_result()
  defp build_draft(provider, blueprint, knowledge, capabilities, opts) do
    request = Request.new(blueprint, knowledge, capabilities, opts)

    provider
    |> TextProvider.call(request, opts)
    |> parse_draft(provider, blueprint)
  end

  @spec parse_draft(draft_result(), TextProvider.provider(), MissionBlueprint.t()) ::
          build_result()
  defp parse_draft({:ok, draft}, provider, blueprint), do: parse_draft(draft, provider, blueprint)

  defp parse_draft({:error, reason}, _planner, blueprint) do
    fallback(blueprint, :planner_error, reason)
  end

  defp parse_draft(draft, provider, blueprint) when is_binary(draft) do
    case DraftParser.parse(draft) do
      {:ok, plan} -> planned(plan, provider, draft)
      {:error, reason} -> fallback(blueprint, :draft_parse_error, reason)
    end
  end

  defp parse_draft(draft, provider, blueprint) do
    fallback(blueprint, :invalid_draft, {provider, draft})
  end

  @spec planned(Plan.t(), TextProvider.provider(), binary()) :: build_result()
  defp planned(%Plan{} = plan, provider, draft) do
    %{
      plan: %{plan | source: :agent_generated},
      trace: [
        {:planned, "Parsed initial plan draft with #{length(plan.steps)} step(s).",
         %{
           planner: provider,
           mode: :draft,
           plan_id: plan.id,
           draft: draft,
           steps: Enum.map(plan.steps, & &1.title)
         }}
      ]
    }
  end

  @spec manual_guided(MissionBlueprint.t()) :: build_result()
  defp manual_guided(%MissionBlueprint{} = blueprint) do
    %{
      plan: blueprint.plan,
      trace: [
        {:planning_started, "Manual guided planning must be driven through the runtime API.",
         %{mode: :guided}}
      ]
    }
  end

  @spec fallback(MissionBlueprint.t(), atom(), term()) :: build_result()
  defp fallback(%MissionBlueprint{} = blueprint, reason, details) do
    %{
      plan: blueprint.plan,
      trace: [
        {:planning_failed, "Planner draft failed; using the blueprint's existing plan.",
         %{reason: reason, details: details}}
      ]
    }
  end
end
