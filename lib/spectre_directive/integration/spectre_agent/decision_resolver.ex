defmodule SpectreDirective.Integration.SpectreAgent.DecisionResolver do
  @moduledoc false

  alias SpectreDirective.AgentDecision
  alias SpectreDirective.Context
  alias SpectreDirective.Invocation
  alias SpectreDirective.Plan
  alias SpectreDirective.PlanPatch
  alias SpectreDirective.Step

  @doc false
  @spec resolve(module(), AgentDecision.t(), Context.t()) ::
          {:ok, AgentDecision.t()} | {:error, term()}
  def resolve(owner, %AgentDecision{kind: :invoke} = decision, context) do
    with {:ok, invocation} <- resolve_invocation(owner, decision.invocation, context) do
      {:ok, %{decision | invocation: invocation}}
    end
  end

  def resolve(
        owner,
        %AgentDecision{kind: :policy, invocation: %Invocation{}} = decision,
        context
      ) do
    with {:ok, invocation} <- resolve_invocation(owner, decision.invocation, context) do
      {:ok, %{decision | invocation: invocation}}
    end
  end

  def resolve(owner, %AgentDecision{kind: :propose_plan} = decision, context) do
    with {:ok, plan} <- resolve_plan(owner, decision.plan, context) do
      {:ok, %{decision | plan: plan}}
    end
  end

  def resolve(owner, %AgentDecision{kind: :propose_patch} = decision, context) do
    with {:ok, patch} <- resolve_patch(owner, decision.patch, context) do
      {:ok, %{decision | patch: patch}}
    end
  end

  def resolve(_owner, %AgentDecision{} = decision, _context), do: {:ok, decision}

  @doc false
  @spec trusted_invocation(term()) :: {:ok, term()} | {:error, term()}
  def trusted_invocation(target) when is_function(target, 1), do: {:ok, target}
  def trusted_invocation(target) when is_atom(target) and not is_nil(target), do: {:ok, target}

  def trusted_invocation({module, opts} = target) when is_atom(module) and is_list(opts),
    do: {:ok, target}

  def trusted_invocation({module, function} = target)
      when is_atom(module) and is_atom(function),
      do: {:ok, target}

  def trusted_invocation({module, function, args} = target)
      when is_atom(module) and is_atom(function) and is_list(args),
      do: {:ok, target}

  def trusted_invocation(target), do: {:error, {:unresolved_directive_invocation, target}}

  @spec resolve_plan(module(), term(), Context.t()) :: {:ok, Plan.t()} | {:error, term()}
  defp resolve_plan(owner, value, context) do
    with {:ok, plan} <- normalize_plan(value),
         {:ok, steps} <- map_ok(plan.steps, &resolve_step(owner, &1, context)) do
      {:ok, %{plan | steps: steps}}
    end
  end

  @spec normalize_plan(term()) :: {:ok, Plan.t()} | {:error, term()}
  defp normalize_plan(%Plan{} = plan), do: {:ok, plan}
  defp normalize_plan(%{steps: steps}), do: new_generated_plan(steps)
  defp normalize_plan(%{"steps" => steps}), do: new_generated_plan(steps)
  defp normalize_plan(steps) when is_list(steps), do: new_generated_plan(steps)
  defp normalize_plan(value), do: {:error, {:invalid_generated_plan, value}}

  @spec new_generated_plan(term()) :: {:ok, Plan.t()} | {:error, term()}
  defp new_generated_plan(steps) do
    {:ok, Plan.new(steps, source: :agent_generated)}
  rescue
    error -> {:error, {:invalid_generated_plan, error}}
  end

  @spec resolve_patch(module(), term(), Context.t()) :: {:ok, PlanPatch.t()} | {:error, term()}
  defp resolve_patch(owner, value, context) do
    with {:ok, patch} <- normalize_patch(value),
         {:ok, operations} <-
           map_ok(patch.operations, &resolve_operation(owner, &1, context)) do
      {:ok, %{patch | operations: operations}}
    end
  end

  @spec normalize_patch(term()) :: {:ok, PlanPatch.t()} | {:error, term()}
  defp normalize_patch(value) do
    {:ok, PlanPatch.new(value)}
  rescue
    error -> {:error, {:invalid_generated_patch, error}}
  end

  @spec resolve_operation(module(), term(), Context.t()) :: {:ok, term()} | {:error, term()}
  defp resolve_operation(owner, {:add, step}, context) do
    with {:ok, step} <- resolve_step(owner, Step.new(step), context), do: {:ok, {:add, step}}
  end

  defp resolve_operation(owner, {:insert_after, step_id, step}, context) do
    with {:ok, step} <- resolve_step(owner, Step.new(step), context),
         do: {:ok, {:insert_after, step_id, step}}
  end

  defp resolve_operation(owner, {:replace, step_id, step}, context) do
    with {:ok, step} <- resolve_step(owner, Step.new(step), context),
         do: {:ok, {:replace, step_id, step}}
  end

  defp resolve_operation(_owner, operation, _context), do: {:ok, operation}

  @spec resolve_step(module(), Step.t(), Context.t()) :: {:ok, Step.t()} | {:error, term()}
  defp resolve_step(_owner, %Step{invoke: nil} = step, _context), do: {:ok, step}

  defp resolve_step(owner, %Step{invoke: target} = step, context) do
    invocation = normalize_generated_invocation(target)

    with {:ok, invocation} <- resolve_invocation(owner, invocation, context) do
      {:ok, %{step | invoke: invocation}}
    end
  end

  @spec normalize_generated_invocation(term()) :: Invocation.t()
  defp normalize_generated_invocation(%Invocation{} = invocation), do: invocation

  defp normalize_generated_invocation(attrs) when is_map(attrs) do
    target = value(attrs, :target) || value(attrs, :name)

    Invocation.new(target,
      policy: value(attrs, :policy),
      metadata: value(attrs, :metadata, %{})
    )
  end

  defp normalize_generated_invocation(target), do: Invocation.new(target)

  @spec resolve_invocation(module(), Invocation.t() | nil, Context.t()) ::
          {:ok, Invocation.t()} | {:error, term()}
  defp resolve_invocation(_owner, nil, _context), do: {:error, :invocation_required}

  defp resolve_invocation(owner, %Invocation{} = invocation, context) do
    with {:ok, target} <- call_invocation_handler(owner, invocation.target, context) do
      {:ok, %{invocation | target: target}}
    end
  end

  @spec call_invocation_handler(module(), term(), Context.t()) ::
          {:ok, term()} | {:error, term()}
  defp call_invocation_handler(owner, target, context) do
    # Model output is only a symbolic request. The host must map it to a
    # trusted function/module/MFA before the runtime is allowed to execute it.
    owner.handle_directive({:invocation, target}, context)
    |> normalize_handler_result()
  rescue
    error -> {:error, {:invocation_handler_failed, error.__struct__, Exception.message(error)}}
  end

  @spec normalize_handler_result(term()) :: {:ok, term()} | {:error, term()}
  defp normalize_handler_result({:ok, resolved}), do: trusted_invocation(resolved)
  defp normalize_handler_result({:error, _reason} = error), do: error
  defp normalize_handler_result(resolved), do: trusted_invocation(resolved)

  @spec map_ok([term()], (term() -> {:ok, term()} | {:error, term()})) ::
          {:ok, [term()]} | {:error, term()}
  defp map_ok(values, function) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, resolved} ->
      case function.(value) do
        {:ok, next} -> {:cont, {:ok, [next | resolved]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reverse_success()
  end

  @spec reverse_success({:ok, [term()]} | {:error, term()}) ::
          {:ok, [term()]} | {:error, term()}
  defp reverse_success({:ok, resolved}), do: {:ok, Enum.reverse(resolved)}
  defp reverse_success({:error, _reason} = error), do: error

  @spec value(map(), atom(), term()) :: term()
  defp value(attrs, key, default \\ nil) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, Atom.to_string(key), default)
    end
  end
end
