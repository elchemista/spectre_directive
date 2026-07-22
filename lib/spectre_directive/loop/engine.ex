defmodule SpectreDirective.Loop.Engine do
  @moduledoc """
  Pure, resumable mission-loop reducer.

  The engine never calls an LLM, function, policy, or user interface. It emits
  one correlated request and applies the correlated response supplied by its
  host.
  """

  alias SpectreDirective.AgentDecision
  alias SpectreDirective.Invocation
  alias SpectreDirective.Invocation.Result, as: InvocationResult
  alias SpectreDirective.Loop.Completion
  alias SpectreDirective.Loop.PlanReducer
  alias SpectreDirective.Loop.State
  alias SpectreDirective.Outcome
  alias SpectreDirective.Plan
  alias SpectreDirective.PlanPatch
  alias SpectreDirective.Request
  alias SpectreDirective.Step
  alias SpectreDirective.WorkingContext

  @terminal_statuses [:completed, :failed, :cancelled]

  @type next_result ::
          {:request, Request.t(), State.t()}
          | {:done, Outcome.t(), State.t()}
          | {:blocked, term(), State.t()}

  @type result :: next_result() | {:error, term(), State.t()}

  @doc "Creates pure mission-loop state."
  @spec new(keyword() | map()) :: {:ok, State.t()} | {:error, term()}
  defdelegate new(attrs), to: State

  @doc "Returns the pending request or advances until the next external boundary."
  @spec next(State.t()) :: next_result()
  def next(%State{status: status, outcome: %Outcome{} = outcome} = state)
      when status in @terminal_statuses,
      do: {:done, outcome, state}

  def next(%State{status: :paused} = state), do: {:blocked, :paused, state}
  def next(%State{status: :blocked} = state), do: {:blocked, :blocked, state}

  def next(%State{iteration: iteration, max_iterations: max_iterations} = state)
      when iteration >= max_iterations do
    state
    |> Completion.fail({:max_iterations_exceeded, max_iterations})
    |> Completion.done_result()
  end

  def next(%State{pending_request: %Request{} = request} = state),
    do: {:request, request, state}

  def next(%State{} = state), do: advance(state)

  @doc "Applies a response only when it matches the live pending request."
  @spec respond(State.t(), binary(), term()) :: result()
  def respond(%State{status: status} = state, _request_id, _response)
      when status in @terminal_statuses,
      do: {:error, :mission_terminal, state}

  def respond(%State{status: :paused} = state, _request_id, _response),
    do: {:error, :mission_paused, state}

  def respond(%State{} = state, request_id, response) when is_binary(request_id) do
    # Correlating all three values prevents delayed LLM/tool replies from
    # changing a mission after its request, plan, or current step moved on.
    with {:ok, request} <- pending_request(state, request_id),
         :ok <- current_plan_version(state, request),
         :ok <- current_step(state, request),
         state <- clear_request(state),
         {:ok, state} <- apply_response(state, request, response) do
      next(state)
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def respond(%State{} = state, request_id, _response),
    do: {:error, {:invalid_request_id, request_id}, state}

  @doc "Adds application-supplied information without completing a pending request."
  @spec inform(State.t(), term(), keyword()) :: {:ok, State.t()} | {:error, term()}
  def inform(state, information, opts \\ [])

  def inform(%State{status: status}, _information, _opts) when status in @terminal_statuses,
    do: {:error, :mission_terminal}

  def inform(%State{} = state, information, opts) when is_list(opts) do
    working_context =
      WorkingContext.add(
        state.working_context,
        information,
        Keyword.put_new(opts, :step_id, current_step_id(state))
      )

    state =
      state
      |> Map.put(:working_context, working_context)
      |> State.add_trace(:information, "Added mission information.", %{
        source: Keyword.get(opts, :source, :application),
        step_id: current_step_id(state)
      })
      |> invalidate_reasoning_request()

    {:ok, state}
  end

  def inform(%State{}, _information, opts), do: {:error, {:invalid_information_options, opts}}

  @doc "Merges application-owned assigns into future callback contexts."
  @spec assign(State.t(), map()) :: {:ok, State.t()} | {:error, term()}
  def assign(%State{status: status}, _assigns) when status in @terminal_statuses,
    do: {:error, :mission_terminal}

  def assign(%State{} = state, assigns) when is_map(assigns) do
    state =
      state
      |> Map.update!(:working_context, &WorkingContext.put_assigns(&1, assigns))
      |> State.add_trace(
        :assigned,
        "Updated application-owned mission assigns.",
        Map.keys(assigns)
      )
      |> invalidate_reasoning_request()

    {:ok, state}
  end

  def assign(%State{}, assigns), do: {:error, {:invalid_assigns, assigns}}

  @doc "Pauses an active mission."
  @spec pause(State.t()) :: {:ok, State.t()} | {:error, term()}
  def pause(%State{status: status}) when status in @terminal_statuses,
    do: {:error, :mission_terminal}

  def pause(%State{} = state) do
    {:ok, state |> State.put_status(:paused) |> State.add_trace(:paused, "Mission paused.")}
  end

  @doc "Resumes a paused or blocked mission."
  @spec resume(State.t()) :: {:ok, State.t()} | {:error, term()}
  def resume(%State{status: status} = state) when status in [:paused, :blocked] do
    {:ok, state |> State.put_status(:running) |> State.add_trace(:resumed, "Mission resumed.")}
  end

  def resume(%State{}), do: {:error, :mission_not_paused}

  @doc "Cancels a live mission."
  @spec cancel(State.t(), term()) :: State.t()
  def cancel(state, reason \\ :cancelled)

  def cancel(%State{} = state, reason), do: Completion.cancel(state, reason)

  @spec advance(State.t()) :: next_result()
  defp advance(%State{} = state) do
    case Plan.current_step(state.plan) do
      %Step{} = step -> advance_step(state, step)
      nil -> select_or_review(state)
    end
  end

  @spec select_or_review(State.t()) :: next_result()
  defp select_or_review(%State{plan_confirmed?: false, plan: %Plan{steps: []}} = state),
    do: reason(state, :plan)

  defp select_or_review(%State{} = state) do
    case Plan.next_pending(state.plan) do
      %Step{} = step ->
        plan = Plan.put_current(state.plan, step)

        state
        |> Map.put(:plan, plan)
        |> Map.put(:step_invoked?, false)
        |> State.put_status(:running)
        |> State.add_trace(:step_started, "Started step: #{step.title}", %{step_id: step.id})
        |> advance()

      nil ->
        reason(state, :mission_review)
    end
  end

  @spec advance_step(State.t(), Step.t()) :: next_result()
  defp advance_step(%State{step_invoked?: false} = state, %Step{invoke: invoke} = step)
       when not is_nil(invoke) do
    invocation = Invocation.new(invoke)
    invocation = if is_nil(step.policy), do: invocation, else: %{invocation | policy: step.policy}

    state
    |> Map.put(:step_invoked?, true)
    |> request_invocation(invocation, :authored_step)
  end

  defp advance_step(%State{} = state, %Step{}), do: reason(state, :step)

  @spec reason(State.t(), atom()) :: next_result()
  defp reason(%State{} = state, operation) do
    context = State.context(state, operation)

    request =
      Request.new(:reason, context,
        target: state.reasoner,
        payload: %{operation: operation, opts: state.reasoner_opts}
      )

    put_request(state, request, "Waiting for mission reasoning.")
  end

  @spec request_invocation(State.t(), Invocation.t(), atom()) :: next_result()
  defp request_invocation(%State{} = state, %Invocation{policy: nil} = invocation, purpose) do
    put_invoke_request(state, invocation, purpose)
  end

  defp request_invocation(%State{} = state, %Invocation{} = invocation, purpose) do
    request_policy(state, invocation.policy, invocation, purpose)
  end

  @spec request_policy(State.t(), term(), Invocation.t() | nil, atom()) :: next_result()
  defp request_policy(%State{} = state, policy, invocation, purpose) do
    request =
      Request.new(:policy, State.context(state, :policy),
        payload: %{policy: policy, invocation: invocation, purpose: purpose}
      )

    put_request(state, request, "Waiting for application policy.")
  end

  @spec put_invoke_request(State.t(), Invocation.t(), atom()) :: next_result()
  defp put_invoke_request(%State{} = state, %Invocation{} = invocation, purpose) do
    context = State.context(state, :invoke)

    request =
      Request.new(:invoke, context,
        target: invocation.target,
        payload: %{invocation: invocation, purpose: purpose}
      )

    put_request(state, request, "Waiting for invocation result.")
  end

  @spec ask(State.t(), term(), map()) :: next_result()
  defp ask(%State{} = state, question, payload) do
    request =
      Request.new(:question, State.context(state, :question),
        payload: Map.put(payload, :question, question)
      )

    put_request(state, request, "Waiting for information.")
  end

  @spec confirm(State.t(), :plan | :patch, term()) :: next_result()
  defp confirm(%State{} = state, proposal_type, proposal) do
    request =
      Request.new(:confirmation, State.context(state, :confirmation),
        payload: %{proposal_type: proposal_type, proposal: proposal}
      )

    state
    |> Map.put(:pending_proposal, {proposal_type, proposal})
    |> put_request(request, "Waiting for plan confirmation.")
  end

  @spec put_request(State.t(), Request.t(), binary()) :: next_result()
  defp put_request(%State{} = state, %Request{} = request, message) do
    state =
      state
      |> Map.put(:pending_request, request)
      |> State.put_status(:waiting)
      |> State.add_trace(:request, message, %{
        request_id: request.id,
        kind: request.kind,
        step_id: request.step_id,
        plan_version: request.plan_version
      })

    {:request, request, state}
  end

  @spec pending_request(State.t(), binary()) :: {:ok, Request.t()} | {:error, term()}
  defp pending_request(%State{pending_request: nil}, _request_id),
    do: {:error, :no_pending_request}

  defp pending_request(%State{pending_request: %Request{id: request_id} = request}, request_id),
    do: {:ok, request}

  defp pending_request(%State{pending_request: %Request{id: expected}}, supplied),
    do: {:error, {:stale_response, supplied, expected}}

  @spec current_plan_version(State.t(), Request.t()) :: :ok | {:error, term()}
  defp current_plan_version(%State{plan: %Plan{version: version}}, %Request{plan_version: version}),
       do: :ok

  defp current_plan_version(%State{plan: %Plan{version: current}}, %Request{plan_version: request}),
       do: {:error, {:stale_plan_response, request, current}}

  @spec current_step(State.t(), Request.t()) :: :ok | {:error, term()}
  defp current_step(_state, %Request{step_id: nil}), do: :ok

  defp current_step(%State{} = state, %Request{step_id: step_id}) do
    case Plan.current_step(state.plan) do
      %Step{id: ^step_id} -> :ok
      %Step{id: current} -> {:error, {:stale_step_response, step_id, current}}
      nil -> {:error, {:stale_step_response, step_id, nil}}
    end
  end

  @spec clear_request(State.t()) :: State.t()
  defp clear_request(%State{} = state) do
    state
    |> Map.put(:pending_request, nil)
    |> State.put_status(:running)
    |> Map.update!(:iteration, &(&1 + 1))
  end

  @spec apply_response(State.t(), Request.t(), term()) :: {:ok, State.t()} | {:error, term()}
  defp apply_response(state, %Request{kind: :reason} = request, response),
    do: apply_reasoning(state, request, response)

  defp apply_response(state, %Request{kind: :invoke} = request, response),
    do: apply_invocation(state, request, response)

  defp apply_response(state, %Request{kind: :question} = request, response) do
    state = add_information(state, response, request, :answer)

    {:ok,
     State.add_trace(state, :answered, "Received requested information.", %{
       request_id: request.id
     })}
  end

  defp apply_response(state, %Request{kind: :policy} = request, response),
    do: apply_policy(state, request, response)

  defp apply_response(state, %Request{kind: :confirmation} = request, response),
    do: apply_confirmation(state, request, response)

  @spec apply_reasoning(State.t(), Request.t(), term()) :: {:ok, State.t()} | {:error, term()}
  defp apply_reasoning(%State{} = state, %Request{} = request, response) do
    case AgentDecision.new(response) do
      {:ok, decision} ->
        state =
          State.add_trace(state, :decision, "Reasoner selected #{decision.kind}.", %{
            kind: decision.kind,
            metadata: decision.metadata,
            request_id: request.id
          })

        apply_decision(state, request, decision)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec apply_decision(State.t(), Request.t(), AgentDecision.t()) ::
          {:ok, State.t()} | {:error, term()}
  defp apply_decision(_state, _request, %AgentDecision{kind: :invoke, invocation: nil}),
    do: {:error, :invocation_required}

  defp apply_decision(state, _request, %AgentDecision{kind: :invoke} = decision) do
    state = put_deferred_request(state, decision.invocation, :reasoner)
    {:ok, state}
  end

  defp apply_decision(state, _request, %AgentDecision{
         kind: :policy,
         invocation: nil,
         policy: policy
       }) do
    {:ok, state |> request_policy(policy, nil, :reasoner_policy) |> result_state()}
  end

  defp apply_decision(state, _request, %AgentDecision{kind: :policy} = decision) do
    invocation = %{decision.invocation | policy: decision.policy}
    {:ok, put_deferred_request(state, invocation, :reasoner)}
  end

  defp apply_decision(state, _request, %AgentDecision{kind: :ask, question: question}) do
    {:ok, put_deferred_question(state, question)}
  end

  defp apply_decision(state, _request, %AgentDecision{kind: :propose_plan, plan: plan}) do
    with {:ok, plan} <- PlanReducer.normalize_proposed(state, plan) do
      apply_plan_change(state, :plan, plan)
    end
  end

  defp apply_decision(state, request, %AgentDecision{kind: :propose_patch} = decision) do
    state = maybe_add_information(state, decision.information, request, :reasoner)
    patch = PlanReducer.with_version(decision.patch, state.plan.version)

    apply_plan_change(state, :patch, patch)
  end

  defp apply_decision(state, request, %AgentDecision{kind: :complete_step, result: result}) do
    state = maybe_add_information(state, result, request, :step_result)
    Completion.complete_step(state, result)
  end

  defp apply_decision(state, request, %AgentDecision{kind: :complete_mission, result: result}) do
    state = maybe_add_information(state, result, request, :mission_result)
    begin_completion(state, result)
  end

  defp apply_decision(state, _request, %AgentDecision{kind: :blocked, reason: reason}) do
    {:ok, put_deferred_question(state, reason, %{type: :blocker})}
  end

  @spec put_deferred_request(State.t(), Invocation.t(), atom()) :: State.t()
  defp put_deferred_request(%State{} = state, %Invocation{} = invocation, purpose) do
    result = request_invocation(state, invocation, purpose)
    result_state(result)
  end

  @spec put_deferred_question(State.t(), term(), map()) :: State.t()
  defp put_deferred_question(%State{} = state, question, payload \\ %{}) do
    state |> ask(question, payload) |> result_state()
  end

  @spec put_deferred_confirmation(State.t(), :plan | :patch, term()) :: State.t()
  defp put_deferred_confirmation(%State{} = state, type, proposal) do
    state |> confirm(type, proposal) |> result_state()
  end

  @spec result_state({:request, Request.t(), State.t()}) :: State.t()
  defp result_state({:request, _request, state}), do: state

  @spec apply_invocation(State.t(), Request.t(), term()) :: {:ok, State.t()} | {:error, term()}
  defp apply_invocation(%State{} = state, %Request{} = request, response) do
    with {:ok, result} <- InvocationResult.normalize(response) do
      state =
        result.information
        |> Enum.reduce(state, &add_information(&2, &1, request, :invocation))
        |> increment_step_attempt()
        |> State.add_trace(:invocation_result, "Received invocation result.", %{
          request_id: request.id,
          transition: result.transition,
          information_count: length(result.information),
          error?: not is_nil(result.error)
        })

      if request.payload[:purpose] == :on_complete do
        Completion.finish(state, request, result)
      else
        apply_invocation_transition(state, request, result)
      end
    end
  end

  @spec apply_invocation_transition(State.t(), Request.t(), InvocationResult.t()) ::
          {:ok, State.t()} | {:error, term()}
  defp apply_invocation_transition(state, _request, %InvocationResult{transition: :reason}),
    do: {:ok, state}

  defp apply_invocation_transition(state, _request, %InvocationResult{
         transition: :complete_step,
         step_result: result
       }),
       do: Completion.complete_step(state, result)

  defp apply_invocation_transition(state, _request, %InvocationResult{
         transition: :complete_mission,
         mission_result: result
       }),
       do: begin_completion(state, result)

  defp apply_invocation_transition(state, _request, %InvocationResult{
         transition: :propose_patch,
         plan_patch: patch
       }) do
    patch = PlanReducer.with_version(patch, state.plan.version)

    apply_plan_change(state, :patch, patch)
  end

  defp apply_invocation_transition(state, _request, %InvocationResult{
         transition: :ask,
         question: question
       }),
       do: {:ok, put_deferred_question(state, question)}

  @spec apply_policy(State.t(), Request.t(), term()) :: {:ok, State.t()}
  defp apply_policy(%State{} = state, %Request{} = request, response) do
    state =
      add_information(
        state,
        %{policy: request.payload.policy, decision: response},
        request,
        :policy
      )

    if policy_allowed?(response) do
      invocation = request.payload.invocation
      purpose = request.payload.purpose

      if is_nil(invocation) do
        {:ok,
         State.add_trace(state, :policy_resolved, "Application policy was resolved.", response)}
      else
        {:ok, state |> put_invoke_request(invocation, purpose) |> result_state()}
      end
    else
      state =
        State.add_trace(state, :policy_denied, "Application policy was not approved.", response)

      if request.payload.purpose == :on_complete do
        {:ok, Completion.fail(state, {:completion_policy_denied, response})}
      else
        {:ok, state}
      end
    end
  end

  @spec apply_confirmation(State.t(), Request.t(), term()) :: {:ok, State.t()} | {:error, term()}
  defp apply_confirmation(%State{} = state, %Request{} = request, response) do
    proposal_type = request.payload.proposal_type
    proposal = request.payload.proposal
    state = %{state | pending_proposal: nil}

    case PlanReducer.confirmation(response, proposal) do
      {:accept, accepted} ->
        PlanReducer.apply_confirmed(state, proposal_type, accepted)

      {:reject, reason} ->
        state =
          state
          |> add_information(%{proposal_rejected: reason}, request, :confirmation)
          |> State.add_trace(:proposal_rejected, "Rejected generated plan change.", reason)

        {:ok, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec begin_completion(State.t(), term()) :: {:ok, State.t()}
  defp begin_completion(%State{} = state, result) do
    case Completion.begin(state, result) do
      {:complete, state} ->
        {:ok, state}

      {:invoke, state, invocation} ->
        state = state |> request_invocation(invocation, :on_complete) |> result_state()
        {:ok, state}
    end
  end

  @spec add_information(State.t(), term(), Request.t(), term()) :: State.t()
  defp add_information(%State{} = state, information, %Request{} = request, source) do
    working_context =
      WorkingContext.add(state.working_context, information,
        source: {source, request.id},
        step_id: request.step_id,
        last_result: information
      )

    %{state | working_context: working_context}
  end

  @spec maybe_add_information(State.t(), term(), Request.t(), term()) :: State.t()
  defp maybe_add_information(state, nil, _request, _source), do: state

  defp maybe_add_information(state, information, request, source),
    do: add_information(state, information, request, source)

  @spec increment_step_attempt(State.t()) :: State.t()
  defp increment_step_attempt(%State{} = state) do
    case Plan.current_step(state.plan) do
      %Step{} = step ->
        %{state | plan: Plan.update_step(state.plan, %{step | attempts: step.attempts + 1})}

      nil ->
        state
    end
  end

  @spec apply_plan_change(State.t(), :plan | :patch, Plan.t() | PlanPatch.t()) ::
          {:ok, State.t()} | {:error, term()}
  defp apply_plan_change(%State{} = state, type, proposal) do
    case PlanReducer.apply_change(state, type, proposal) do
      {:confirm, state} -> {:ok, put_deferred_confirmation(state, type, proposal)}
      {:ok, _state} = result -> result
      {:error, _reason} = error -> error
    end
  end

  @spec policy_allowed?(term()) :: boolean()
  defp policy_allowed?({:ok, response}), do: policy_allowed?(response)
  defp policy_allowed?(response), do: response in [:allow, :approved, :accept, true]

  @spec current_step_id(State.t()) :: binary() | nil
  defp current_step_id(%State{} = state) do
    case Plan.current_step(state.plan) do
      %Step{id: id} -> id
      nil -> nil
    end
  end

  @spec invalidate_reasoning_request(State.t()) :: State.t()
  # New information changes an LLM's input. Only reasoning is restarted;
  # invocation and policy effects remain correlated and run to completion.
  defp invalidate_reasoning_request(%State{pending_request: %Request{kind: :reason}} = state) do
    state
    |> Map.put(:pending_request, nil)
    |> restore_after_invalidation()
    |> State.add_trace(:request_invalidated, "Restarting reasoning with newer mission context.")
  end

  defp invalidate_reasoning_request(%State{} = state), do: state

  @spec restore_after_invalidation(State.t()) :: State.t()
  defp restore_after_invalidation(%State{status: :waiting} = state),
    do: State.put_status(state, :running)

  defp restore_after_invalidation(%State{} = state), do: state
end
