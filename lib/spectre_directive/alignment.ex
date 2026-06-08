defmodule SpectreDirective.Alignment do
  @moduledoc """
  Mission-alignment boundary.

  Real alignment is expected to come from an application module configured with
  `alignment: MyApp.Alignment` or `config :spectre_directive, alignment:
  MyApp.Alignment`. SpectreDirective builds a rich
  `SpectreDirective.Alignment.Request` and lets that module decide whether to
  continue, skip, pause, ask, revise, or finish.

  When no provider is configured, SpectreDirective uses a deliberately small
  conservative fallback for safety checks such as missing capabilities and high
  risk. It is not intended to replace a smarter alignment model.
  """

  alias SpectreDirective.Alignment.Request
  alias SpectreDirective.Alignment.Result
  alias SpectreDirective.CapabilitySnapshot
  alias SpectreDirective.Step

  @type alignment_result ::
          Result.t()
          | map()
          | keyword()
          | {:ok, Result.t() | map() | keyword()}
          | {:error, term()}

  @callback check_alignment(Request.t(), keyword()) :: alignment_result()

  @checks [
    :mission_relevance,
    :context_relevance,
    :information_value,
    :confidence,
    :cost,
    :risk,
    :capability,
    :drift,
    :redundancy,
    :strategy
  ]

  @doc """
  Returns alignment vocabulary understood by the built-in prompt and result type.
  """
  @spec checks() :: [atom()]
  def checks, do: @checks

  @doc """
  Checks whether a step still serves the mission.
  """
  @spec check(map(), Step.t() | nil, :pre_step | :post_step) :: Result.t()
  def check(state, step, phase) do
    request = Request.new(state, step, phase)

    opts = Map.get(state, :opts, [])

    case alignment_module(opts) do
      nil ->
        fallback(request)

      module ->
        module
        |> call_alignment(request, opts)
        |> normalize_alignment_result(request, module)
    end
  end

  @spec alignment_module(keyword()) :: module() | nil
  defp alignment_module(opts) do
    Keyword.get(opts, :alignment) || Application.get_env(:spectre_directive, :alignment)
  end

  @spec call_alignment(module(), Request.t(), keyword()) :: alignment_result()
  defp call_alignment(module, %Request{} = request, opts) when is_atom(module) do
    module.check_alignment(request, opts)
  rescue
    error -> {:error, {:alignment_failed, module, error}}
  catch
    kind, reason -> {:error, {:alignment_failed, module, {kind, reason}}}
  end

  @spec normalize_alignment_result(alignment_result(), Request.t(), module()) ::
          Result.t()
  defp normalize_alignment_result({:ok, result}, request, module),
    do: normalize_alignment_result(result, request, module)

  defp normalize_alignment_result(%Result{} = result, %Request{} = request, module) do
    %{
      result
      | phase: request.phase,
        metadata: Map.put_new(result.metadata, :alignment, module)
    }
  end

  defp normalize_alignment_result(result, %Request{} = request, module)
       when is_map(result) or is_list(result) do
    result
    |> Result.new()
    |> normalize_alignment_result(request, module)
  end

  defp normalize_alignment_result({:error, reason}, %Request{} = request, module) do
    Result.new(
      status: :blocked,
      recommendation: :ask,
      phase: request.phase,
      check: :alignment,
      reason: "Alignment module failed; human or supervisor review is required.",
      metadata: %{alignment: module, alignment_error: reason}
    )
  end

  defp normalize_alignment_result(result, %Request{} = request, module) do
    Result.new(
      status: :blocked,
      recommendation: :ask,
      phase: request.phase,
      check: :alignment,
      reason: "Alignment module returned an invalid result.",
      metadata: %{alignment: module, invalid_result: result}
    )
  end

  @spec fallback(Request.t()) :: Result.t()
  defp fallback(%Request{step: nil, phase: phase}) do
    Result.new(
      status: :complete_enough,
      recommendation: :finish,
      phase: phase,
      check: :confidence,
      reason: "No useful pending step remains.",
      metadata: %{provider: :fallback}
    )
  end

  defp fallback(%Request{state: %{status: status}, phase: phase})
       when status in [:finished, :stopped, :aborted] do
    Result.new(
      status: :complete_enough,
      recommendation: :finish,
      phase: phase,
      check: :confidence,
      reason: "Mission is already in a terminal state.",
      metadata: %{provider: :fallback}
    )
  end

  defp fallback(
         %Request{state: state, step: %Step{} = step, capabilities: capabilities, phase: phase} =
           request
       ) do
    decisions = get_in(state, [:knowledge, Access.key(:decisions)]) || []

    cond do
      Enum.any?(decisions, &contains?(&1, "finish early")) ->
        Result.new(
          status: :complete_enough,
          recommendation: :finish,
          phase: phase,
          check: :confidence,
          reason: "Current knowledge contains an explicit finish-early decision.",
          metadata: %{provider: :fallback}
        )

      not is_nil(step.required_capability) and
          is_nil(CapabilitySnapshot.find(capabilities, step.required_capability)) ->
        Result.new(
          status: :blocked,
          recommendation: :ask,
          phase: phase,
          check: :capability,
          reason: "The required capability is not available now.",
          metadata: %{provider: :fallback, required_capability: step.required_capability}
        )

      true ->
        fallback_risk_or_continue(request)
    end
  end

  @spec fallback_risk_or_continue(Request.t()) :: Result.t()
  defp fallback_risk_or_continue(%Request{step: %Step{} = step, state: state, phase: phase}) do
    if risky_without_approval?(state, step) do
      Result.new(
        status: :risky,
        recommendation: :pause,
        phase: phase,
        check: :risk,
        score: risk_score(step.risk),
        reason: "The step carries high risk or requires approval.",
        metadata: %{provider: :fallback}
      )
    else
      Result.new(
        status: :aligned,
        recommendation: :continue,
        phase: phase,
        check: :alignment,
        score: 0.5,
        reason: "No alignment provider configured; conservative fallback allowed the step.",
        metadata: %{provider: :fallback}
      )
    end
  end

  @spec risky_without_approval?(map(), Step.t()) :: boolean()
  defp risky_without_approval?(%{approvals: approvals}, %Step{} = step) do
    step.risk in [:high, :critical] and not MapSet.member?(approvals, step.id)
  end

  defp risky_without_approval?(_state, %Step{} = step), do: step.risk in [:high, :critical]

  @spec risk_score(atom()) :: float()
  defp risk_score(:high), do: 0.8
  defp risk_score(:critical), do: 1.0
  defp risk_score(_risk), do: 0.5

  @spec contains?(term(), binary()) :: boolean()
  defp contains?(value, text) do
    value
    |> to_string()
    |> String.downcase()
    |> String.contains?(text)
  end
end
