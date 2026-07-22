defmodule SpectreDirective.PlanPatch do
  @moduledoc """
  An atomic, version-correlated change to a living plan.
  """

  alias SpectreDirective.Plan
  alias SpectreDirective.Step

  @type operation ::
          {:add, Step.t() | map() | keyword()}
          | {:insert_after, binary(), Step.t() | map() | keyword()}
          | {:remove, binary()}
          | {:replace, binary(), Step.t() | map() | keyword()}
          | {:skip, binary(), term()}
          | {:reorder, [binary()]}

  @type t :: %__MODULE__{
          base_version: pos_integer() | nil,
          operations: [operation()],
          reason: binary(),
          metadata: map()
        }

  defstruct [:base_version, operations: [], reason: "Plan updated.", metadata: %{}]

  @operation_names %{
    :add => :add,
    "add" => :add,
    :insert_after => :insert_after,
    "insert_after" => :insert_after,
    :remove => :remove,
    "remove" => :remove,
    :replace => :replace,
    "replace" => :replace,
    :skip => :skip,
    "skip" => :skip,
    :reorder => :reorder,
    "reorder" => :reorder
  }

  @doc "Builds a plan patch."
  @spec new(t() | map() | keyword() | [operation()]) :: t()
  def new(%__MODULE__{} = patch), do: patch

  def new(attrs) when is_list(attrs) do
    if patch_options?(attrs) do
      build(Map.new(attrs))
    else
      %__MODULE__{operations: Enum.map(attrs, &normalize_operation/1)}
    end
  end

  def new(attrs) when is_map(attrs), do: build(attrs)
  def new(operation), do: %__MODULE__{operations: [operation]}

  @spec patch_options?(list()) :: boolean()
  defp patch_options?(attrs) do
    Keyword.keyword?(attrs) and
      Enum.any?(attrs, fn {key, _value} ->
        key in [:base_version, :operations, :reason, :metadata]
      end)
  end

  @spec build(map()) :: t()
  defp build(attrs) do
    attrs = Map.new(attrs)

    %__MODULE__{
      base_version: value(attrs, :base_version),
      operations:
        attrs |> value(:operations, []) |> List.wrap() |> Enum.map(&normalize_operation/1),
      reason: to_string(value(attrs, :reason, "Plan updated.")),
      metadata: Map.new(value(attrs, :metadata, %{}))
    }
  end

  @doc "Applies every patch operation or leaves the original plan untouched."
  @spec apply(Plan.t(), t() | map() | keyword()) :: {:ok, Plan.t()} | {:error, term()}
  def apply(%Plan{} = plan, patch) do
    patch = new(patch)

    with :ok <- validate_version(plan, patch),
         {:ok, changed} <- Enum.reduce_while(patch.operations, {:ok, plan}, &apply_operation/2) do
      revision = %{
        version: plan.version + 1,
        reason: patch.reason,
        patch: patch,
        timestamp: DateTime.utc_now()
      }

      {:ok,
       %{
         changed
         | version: plan.version + 1,
           reason: patch.reason,
           revision_history: plan.revision_history ++ [revision]
       }}
    end
  rescue
    error -> {:error, {:invalid_plan_patch, error}}
  end

  @spec validate_version(Plan.t(), t()) :: :ok | {:error, term()}
  defp validate_version(%Plan{version: version}, %__MODULE__{base_version: base})
       when is_nil(base) or base == version,
       do: :ok

  defp validate_version(%Plan{version: version}, %__MODULE__{base_version: base}),
    do: {:error, {:stale_plan_patch, base, version}}

  @spec apply_operation(operation(), {:ok, Plan.t()} | {:error, term()}) ::
          {:cont, {:ok, Plan.t()}} | {:halt, {:error, term()}}
  defp apply_operation(operation, {:ok, plan}) do
    case do_apply_operation(plan, operation) do
      {:ok, changed} -> {:cont, {:ok, changed}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  @spec do_apply_operation(Plan.t(), operation()) :: {:ok, Plan.t()} | {:error, term()}
  defp do_apply_operation(%Plan{} = plan, {:add, step}) do
    {:ok, %{plan | steps: plan.steps ++ [normalize_step(step)]}}
  end

  defp do_apply_operation(%Plan{} = plan, {:insert_after, step_id, step}) do
    with {:ok, index} <- step_index(plan, step_id) do
      {left, right} = Enum.split(plan.steps, index + 1)
      {:ok, %{plan | steps: left ++ [normalize_step(step)] ++ right}}
    end
  end

  defp do_apply_operation(%Plan{} = plan, {:remove, step_id}) do
    with {:ok, step} <- fetch_step(plan, step_id),
         :ok <- mutable_step(step) do
      {:ok, %{plan | steps: Enum.reject(plan.steps, &(&1.id == step_id))}}
    end
  end

  defp do_apply_operation(%Plan{} = plan, {:replace, step_id, replacement}) do
    with {:ok, step} <- fetch_step(plan, step_id),
         :ok <- mutable_step(step) do
      replacement = normalize_step(replacement)

      steps =
        Enum.map(plan.steps, fn
          %Step{id: ^step_id} -> replacement
          existing -> existing
        end)

      {:ok, %{plan | steps: steps}}
    end
  end

  defp do_apply_operation(%Plan{} = plan, {:skip, step_id, reason}) do
    with {:ok, step} <- fetch_step(plan, step_id),
         :ok <- skippable_step(step) do
      skipped = %{step | status: :skipped, result: reason}

      plan = Plan.update_step(plan, skipped)
      plan = if plan.current_step_id == step_id, do: Plan.put_current(plan, nil), else: plan
      {:ok, plan}
    end
  end

  defp do_apply_operation(%Plan{} = plan, {:reorder, step_ids}) when is_list(step_ids) do
    pending = Enum.filter(plan.steps, &(&1.status == :pending))
    pending_ids = Enum.map(pending, & &1.id)

    if MapSet.new(step_ids) == MapSet.new(pending_ids) and length(step_ids) == length(pending_ids) do
      by_id = Map.new(pending, &{&1.id, &1})
      ordered = Enum.map(step_ids, &Map.fetch!(by_id, &1))
      {:ok, %{plan | steps: replace_pending(plan.steps, ordered)}}
    else
      {:error, {:invalid_reorder, step_ids, pending_ids}}
    end
  end

  defp do_apply_operation(_plan, operation), do: {:error, {:invalid_plan_operation, operation}}

  @spec normalize_operation(term()) :: term()
  defp normalize_operation(%{} = operation) do
    operation
    |> operation_name()
    |> build_operation(operation)
  end

  defp normalize_operation(operation), do: operation

  @spec operation_name(map()) :: atom() | nil
  defp operation_name(operation) do
    name = value(operation, :op) || value(operation, :operation) || value(operation, :type)
    Map.get(@operation_names, name)
  end

  @spec build_operation(atom() | nil, map()) :: operation() | map()
  defp build_operation(:add, operation), do: {:add, value(operation, :step)}

  defp build_operation(:insert_after, operation) do
    {:insert_after, value(operation, :step_id) || value(operation, :after),
     value(operation, :step)}
  end

  defp build_operation(:remove, operation), do: {:remove, value(operation, :step_id)}

  defp build_operation(:replace, operation),
    do: {:replace, value(operation, :step_id), value(operation, :step)}

  defp build_operation(:skip, operation),
    do: {:skip, value(operation, :step_id), value(operation, :reason)}

  defp build_operation(:reorder, operation),
    do: {:reorder, value(operation, :step_ids, [])}

  defp build_operation(nil, operation), do: operation

  @spec normalize_step(Step.t() | map() | keyword()) :: Step.t()
  defp normalize_step(%Step{} = step), do: %{step | status: :pending}
  defp normalize_step(step), do: Step.new(step, source: :generated, status: :pending)

  @spec fetch_step(Plan.t(), binary()) :: {:ok, Step.t()} | {:error, term()}
  defp fetch_step(%Plan{} = plan, step_id) do
    case Enum.find(plan.steps, &(&1.id == step_id)) do
      nil -> {:error, {:step_not_found, step_id}}
      step -> {:ok, step}
    end
  end

  @spec step_index(Plan.t(), binary()) :: {:ok, non_neg_integer()} | {:error, term()}
  defp step_index(%Plan{} = plan, step_id) do
    case Enum.find_index(plan.steps, &(&1.id == step_id)) do
      nil -> {:error, {:step_not_found, step_id}}
      index -> {:ok, index}
    end
  end

  @spec mutable_step(Step.t()) :: :ok | {:error, term()}
  defp mutable_step(%Step{status: :pending}), do: :ok
  defp mutable_step(%Step{} = step), do: {:error, {:step_not_mutable, step.id, step.status}}

  @spec skippable_step(Step.t()) :: :ok | {:error, term()}
  defp skippable_step(%Step{status: status}) when status in [:pending, :running], do: :ok
  defp skippable_step(%Step{} = step), do: {:error, {:step_not_skippable, step.id, step.status}}

  @spec replace_pending([Step.t()], [Step.t()]) :: [Step.t()]
  defp replace_pending(steps, ordered) do
    {result, []} =
      Enum.map_reduce(steps, ordered, fn
        %Step{status: :pending}, [next | rest] -> {next, rest}
        step, rest -> {step, rest}
      end)

    result
  end

  @spec value(map(), atom(), term()) :: term()
  defp value(attrs, key, default \\ nil) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, Atom.to_string(key), default)
    end
  end
end
