defmodule Spectre.Directive.ServerTool do
  @moduledoc """
  Pure Directive reducer exposed through Stack-generated Server helpers.

  A portable, bounded canonical binary carries the complete loop across
  checkpoints. Requests are returned as data: the Server calls its model for
  `:reason`, obtains user answers for questions, and proposes effects through
  GAM for `:invoke`. This adapter never starts a second actor or invokes a target.
  """
  alias Spectre.GAM.Canonical.Value
  alias SpectreDirective.Loop.State

  @records [
    State,
    SpectreDirective.Mission,
    SpectreDirective.Plan,
    SpectreDirective.Step,
    SpectreDirective.Request,
    SpectreDirective.Context,
    SpectreDirective.WorkingContext,
    SpectreDirective.Information,
    SpectreDirective.Outcome,
    SpectreDirective.Trace.Entry,
    SpectreDirective.PlanPatch,
    SpectreDirective.AgentDecision,
    SpectreDirective.Invocation,
    SpectreDirective.Invocation.Result,
    DateTime,
    NaiveDateTime,
    Date,
    Time,
    MapSet
  ]

  def tools(_config) do
    operations =
      Map.new([:new, :next, :respond, :inform], fn op ->
        {op, %{path: :cognitive, retry: :safe, max_bytes: 1_048_576}}
      end)

    %{directive: %{contract: 1, adapter: __MODULE__, default: nil, operations: operations}}
  end

  def prepare(:new, [attrs], _trusted) when is_map(attrs), do: {:ok, attrs}
  def prepare(:next, [state], _trusted) when is_binary(state), do: valid_state(state, %{})

  def prepare(:respond, [state, id, response], _trusted) when is_binary(state) and is_binary(id),
    do: valid_state(state, %{request_id: id, response: response})

  def prepare(:inform, [state, information], _trusted) when is_binary(state),
    do: valid_state(state, %{information: information})

  def prepare(_operation, _payload, _trusted), do: {:error, :invalid_directive_request}

  def invoke(:new, attrs, _context) do
    with {:ok, state} <- SpectreDirective.new(attrs), do: SpectreDirective.next(state)
  end

  def invoke(:next, %{state: encoded}, _context) do
    with {:ok, state} <- decode(encoded), do: SpectreDirective.next(state)
  end

  def invoke(:respond, %{state: encoded, request_id: id, response: response}, _context) do
    with {:ok, state} <- decode(encoded), do: SpectreDirective.respond(state, id, response)
  end

  def invoke(:inform, %{state: encoded, information: information}, _context) do
    with {:ok, state} <- decode(encoded),
         {:ok, updated} <- SpectreDirective.inform(state, information),
         do: SpectreDirective.next(updated)
  end

  def project(_operation, {status, data, %State{} = state})
      when status in [:request, :done, :blocked, :error] do
    with {:ok, encoded} <- Value.encode(state, allowed_structs: @records, max_bytes: 900_000),
         {:ok, plain} <- projection(data) do
      {:ok, {:directive, %{status: status, data: plain, state: encoded}}}
    end
  end

  def project(_operation, {:error, reason}) do
    with {:ok, plain} <- projection(reason), do: {:ok, {:error, plain}}
  end

  def project(_operation, _result), do: {:error, :invalid_directive_result}

  @doc "Restores only the bounded, known pure-loop representation; never executable ETF."
  def decode(encoded) do
    case Value.decode(encoded, allowed_structs: @records, max_bytes: 900_000) do
      {:ok, %State{} = state} -> {:ok, state}
      {:ok, _} -> {:error, :invalid_directive_state}
      {:error, _} = error -> error
    end
  end

  defp valid_state(encoded, extra) do
    with {:ok, _} <- decode(encoded), do: {:ok, Map.put(extra, :state, encoded)}
  end

  defp projection(%DateTime{} = value), do: {:ok, DateTime.to_iso8601(value)}
  defp projection(%MapSet{} = value), do: projection(MapSet.to_list(value))
  defp projection(%_{} = value), do: value |> Map.from_struct() |> projection()
  defp projection(value) when is_map(value), do: map_values(value)
  defp projection(value) when is_list(value), do: list_values(value)

  defp projection(value) when is_tuple(value) do
    with {:ok, values} <- value |> Tuple.to_list() |> list_values(),
         do: {:ok, List.to_tuple(values)}
  end

  defp projection(value) do
    with :ok <- Value.validate(value), do: {:ok, value}
  end

  defp map_values(values) do
    Enum.reduce_while(values, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case projection(value) do
        {:ok, item} -> {:cont, {:ok, Map.put(acc, key, item)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp list_values(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case projection(value) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end
end
