defmodule SpectreDirective.Runtime.ObservationRecorder do
  @moduledoc """
  Completes the current step and records what the mission learned.

  This module handles the post-step learning half of the directive loop:

      Step -> Observation -> Impact -> Knowledge -> Correction -> Trace

  Observations are raw reports of what happened. Impact answers "so what for
  this mission?" Corrections express what should change because of the new
  knowledge. The runtime stores all three together so humans and monitor agents
  can inspect both the event and the reason it mattered.
  """

  alias SpectreDirective.Correction
  alias SpectreDirective.Impact
  alias SpectreDirective.Knowledge
  alias SpectreDirective.MemoryStore
  alias SpectreDirective.Observation
  alias SpectreDirective.Plan
  alias SpectreDirective.Runtime.PlanReviser
  alias SpectreDirective.Runtime.State
  alias SpectreDirective.Step

  @doc """
  Applies an observation payload to the current running step.
  """
  @spec complete_current(State.t(), term()) :: State.t()
  def complete_current(%State{} = state, observation_payload) do
    state.plan
    |> Plan.current_step()
    |> complete_step(state, observation_payload)
  end

  @spec complete_step(Step.t() | nil, State.t(), term()) :: State.t()
  defp complete_step(nil, state, observation_payload) do
    State.add_trace(
      state,
      :observation_ignored,
      "Observation ignored because no step is running.",
      observation_payload
    )
  end

  defp complete_step(%Step{} = step, state, observation_payload) do
    observation = Observation.new(observation_payload, step_id: step.id)
    impact = derive_impact(observation, step)
    correction = correction_from_observation(observation)

    state
    # Knowledge is updated before correction so plan revision sees the newest
    # mission facts, decisions, confidence, and open questions.
    |> record_completed_step(step, observation, impact, correction)
    |> PlanReviser.apply(correction, observation, impact)
    |> remember_step(observation, impact, correction)
    |> State.add_trace(:observation, observation.summary || "Recorded observation.", %{
      step_id: step.id,
      impact: impact,
      correction: correction
    })
  end

  @spec record_completed_step(State.t(), Step.t(), Observation.t(), Impact.t(), Correction.t()) ::
          State.t()
  defp record_completed_step(state, step, observation, impact, correction) do
    completed = %{
      step
      | status: :completed,
        attempts: step.attempts + 1,
        evidence: step.evidence ++ observation.evidence,
        result: %{observation: observation, impact: impact, correction: correction}
    }

    state
    |> Map.update!(:knowledge, &Knowledge.record_observation(&1, observation))
    |> State.put_step(completed)
    |> State.clear_current_step()
  end

  @spec derive_impact(Observation.t(), Step.t()) :: Impact.t()
  defp derive_impact(%Observation{impact: %Impact{} = impact}, _step), do: impact

  defp derive_impact(%Observation{impact: impact}, _step) when is_binary(impact),
    do: Impact.new(impact)

  defp derive_impact(%Observation{} = observation, step) do
    # If an adapter or agent did not provide explicit impact, keep the mission
    # loop honest by deriving a conservative impact from relevance fields.
    Impact.new(impact_summary(observation), step_id: step.id, evidence: observation.evidence)
  end

  @spec impact_summary(Observation.t()) :: binary()
  defp impact_summary(%Observation{mission_relevant_facts: [_ | _]}) do
    "The observation added mission-relevant evidence."
  end

  defp impact_summary(%Observation{low_relevance_facts: [_ | _]}) do
    "The observation appears true but low-value for the mission."
  end

  defp impact_summary(%Observation{}) do
    "The observation updated mission knowledge."
  end

  @spec correction_from_observation(Observation.t()) :: Correction.t()
  defp correction_from_observation(%Observation{correction: %Correction{} = correction}),
    do: correction

  defp correction_from_observation(%Observation{correction: nil}), do: Correction.new(:continue)

  defp correction_from_observation(%Observation{correction: type}) when is_atom(type),
    do: Correction.new(type)

  defp correction_from_observation(%Observation{correction: attrs}), do: Correction.new(attrs)

  @spec remember_step(State.t(), Observation.t(), Impact.t(), Correction.t()) :: State.t()
  defp remember_step(state, observation, impact, correction) do
    MemoryStore.remember(
      %{
        mission_id: state.blueprint.mission.id,
        mission: state.blueprint.mission.goal,
        observation: observation,
        impact: impact,
        correction: correction
      },
      state.opts
    )

    state
  end
end
