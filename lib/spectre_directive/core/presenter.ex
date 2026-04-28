defmodule SpectreDirective.Presenter do
  @moduledoc """
  Text renderers for LLM/operator-facing task reports.

  Structured APIs are still the source of truth. This module turns those
  structs and maps into compact, deterministic text that an agent can read.
  """

  alias SpectreDirective.{Event, Job, Task}

  @recent_event_limit 5
  @max_value_chars 600

  @doc """
  Renders one task as compact text for an agent or operator.
  """
  @spec task(Task.t()) :: binary()
  def task(%Task{} = task) do
    [
      "Task #{task.id}",
      "status: #{task.status}",
      maybe_line("title", task.title),
      "job: #{job_type(task.job)}",
      "attempt: #{task.attempt}",
      maybe_line("session", task.session_id),
      maybe_line("started_at", format_time(task.started_at)),
      maybe_line("finished_at", format_time(task.finished_at)),
      maybe_line("last_event", task.last_event),
      maybe_line("last_event_at", format_time(task.last_event_at)),
      maybe_line("last_message", task.last_message),
      progress_line(task.progress),
      result_line(task),
      error_line(task),
      recent_events_line(task.events)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  @doc """
  Renders a list of events in chronological text form.
  """
  @spec events([Event.t()]) :: binary()
  def events(events) when is_list(events) do
    events
    |> Enum.map(&event/1)
    |> case do
      [] -> "No events recorded."
      lines -> Enum.join(lines, "\n")
    end
  end

  @doc """
  Renders one event.
  """
  @spec event(Event.t()) :: binary()
  def event(%Event{} = event) do
    "#{format_time(event.timestamp)} #{event.type}: #{compact(event.payload)}"
  end

  @doc """
  Renders a manager snapshot as an LLM-readable report.
  """
  @spec snapshot(map()) :: binary()
  def snapshot(snapshot) when is_map(snapshot) do
    queued = Map.get(snapshot, :queued, [])
    running = Map.get(snapshot, :running, [])
    completed = Map.get(snapshot, :completed, [])
    retrying = Map.get(snapshot, :retrying, [])

    [
      "SpectreDirective task report",
      "queued=#{length(queued)} running=#{length(running)} completed=#{length(completed)} retrying=#{length(retrying)}",
      agent_totals_line(Map.get(snapshot, :agent_totals)),
      maybe_line("rate_limits", Map.get(snapshot, :rate_limits)),
      section("Running", Enum.map(running, &task_summary/1), "No running tasks."),
      section("Retrying", Enum.map(retrying, &retry_summary/1), "No retrying tasks."),
      section(
        "Recently completed",
        completed |> Enum.take(-5) |> Enum.map(&task_summary/1),
        "No completed tasks."
      )
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  @doc """
  Explains a known task error in plain language.
  """
  @spec error(term()) :: binary()
  def error(:not_found), do: "Task was not found."
  def error(:cancelled), do: "Task was cancelled before it completed."
  def error(:timeout), do: "Timed out while waiting for the task to finish."

  def error({:host_execution_not_allowed, isolation}) do
    "Host execution was blocked by policy. Requested isolation: #{compact(isolation)}. Enable it explicitly on the job or call context only if this command is trusted."
  end

  def error({:invalid_job, field}) do
    "Task definition is invalid: #{field} is missing or not acceptable."
  end

  def error({:runtime_unavailable, runtime}) do
    "Required runtime is unavailable: #{runtime}. Install/configure it or choose another job type."
  end

  def error({:exit_status, status, result}) do
    output = Map.get(result, :output) || Map.get(result, "output")
    "Command exited with status #{status}. Output: #{compact(output)}"
  end

  def error({:timeout, timeout_ms, details}) do
    "Task timed out after #{timeout_ms}ms. Details: #{compact(details)}"
  end

  def error({:optional_runtime_unavailable, runtime}) do
    "Optional integration is unavailable: #{runtime}. Directive can run standalone, but this request asked to use that integration."
  end

  def error({:kinetic_plan_failed, reason}) do
    "SpectreKinetic could not plan the AL request. Reason: #{compact(reason)}"
  end

  def error({:unsupported_al, al}) do
    "Directive does not know how to resolve this AL instruction yet: #{compact(al)}"
  end

  def error({:exception, exception, _stack}) do
    "Task crashed with exception: #{Exception.message(exception)}"
  rescue
    _ -> "Task crashed with exception: #{inspect(exception)}"
  end

  def error({:exit, reason}) do
    "Task exited unexpectedly: #{compact(reason)}"
  end

  def error({:throw, reason}) do
    "Task threw unexpectedly: #{compact(reason)}"
  end

  def error({:command_start_failed, reason}) do
    "Command could not be started. Reason: #{error(reason)}"
  end

  def error(reason), do: "Task failed: #{compact(reason)}"

  @spec task_summary(Task.t()) :: binary()
  defp task_summary(%Task{} = task) do
    parts = [
      "- #{task.id}",
      "status=#{task.status}",
      "job=#{job_type(task.job)}",
      maybe_inline("session", task.session_id),
      maybe_inline("last_event", task.last_event),
      maybe_inline("last_message", task.last_message),
      maybe_inline("error", error_brief(task.error))
    ]

    parts
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
  end

  @spec retry_summary(map()) :: binary()
  defp retry_summary(retry) when is_map(retry) do
    "- #{Map.get(retry, :task_id)} attempt=#{Map.get(retry, :attempt)} due_in_ms=#{Map.get(retry, :due_in_ms)} error=#{compact(Map.get(retry, :error))}"
  end

  @spec section(binary(), [binary()], binary()) :: binary()
  defp section(_title, [], empty), do: empty

  defp section(title, lines, _empty) do
    ([title <> ":"] ++ lines)
    |> Enum.join("\n")
  end

  @spec progress_line(term()) :: binary() | nil
  defp progress_line(progress) when is_map(progress) and map_size(progress) > 0 do
    "progress: #{compact(progress)}"
  end

  defp progress_line(_progress), do: nil

  @spec result_line(map()) :: binary() | nil
  defp result_line(%{status: :succeeded, result: result}), do: maybe_line("result", result)
  defp result_line(_task), do: nil

  @spec error_line(map()) :: binary() | nil
  defp error_line(%{status: :failed, error: reason}), do: "error: #{error(reason)}"
  defp error_line(%{error: nil}), do: nil
  defp error_line(%{error: reason}), do: "error: #{error(reason)}"

  @spec recent_events_line(term()) :: binary() | nil
  defp recent_events_line(events) when is_list(events) and events != [] do
    rendered =
      events
      |> Enum.reverse()
      |> Enum.take(-@recent_event_limit)
      |> Enum.map_join("\n", &event/1)

    "recent_events:\n" <> rendered
  end

  defp recent_events_line(_events), do: nil

  @spec agent_totals_line(map() | nil) :: binary() | nil
  defp agent_totals_line(nil), do: nil

  defp agent_totals_line(totals) when is_map(totals) do
    "agent_totals: input=#{Map.get(totals, :input_tokens, 0)} output=#{Map.get(totals, :output_tokens, 0)} total=#{Map.get(totals, :total_tokens, 0)} seconds=#{Map.get(totals, :seconds_running, 0)}"
  end

  @spec job_type(term()) :: term()
  defp job_type(job) do
    case Job.describe(job) do
      %{type: type} -> type
      %{"type" => type} -> type
      _ -> inspect(job.__struct__)
    end
  rescue
    _ -> inspect(job)
  end

  @spec maybe_line(binary(), term()) :: binary() | nil
  defp maybe_line(_label, nil), do: nil
  defp maybe_line(_label, ""), do: nil
  defp maybe_line(label, value), do: "#{label}: #{compact(value)}"

  @spec maybe_inline(binary(), term()) :: binary() | nil
  defp maybe_inline(_label, nil), do: nil
  defp maybe_inline(_label, ""), do: nil
  defp maybe_inline(_label, []), do: nil
  defp maybe_inline(_label, %{} = map) when map_size(map) == 0, do: nil
  defp maybe_inline(label, value), do: "#{label}=#{compact(value)}"

  @spec error_brief(term()) :: binary() | nil
  defp error_brief(nil), do: nil
  defp error_brief(reason), do: error(reason)

  @spec format_time(term()) :: binary() | nil | term()
  defp format_time(nil), do: nil
  defp format_time(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_time(value), do: value

  @spec compact(term()) :: binary() | nil
  defp compact(value) when is_binary(value), do: truncate(value)
  defp compact(value) when is_atom(value), do: Atom.to_string(value)

  defp compact(value) when is_integer(value) or is_float(value) or is_boolean(value),
    do: to_string(value)

  defp compact(nil), do: nil

  defp compact(value) do
    value
    |> inspect(limit: 20, printable_limit: @max_value_chars)
    |> truncate()
  end

  @spec truncate(binary()) :: binary()
  defp truncate(value) when is_binary(value) do
    if String.length(value) > @max_value_chars do
      String.slice(value, 0, @max_value_chars) <> "...(truncated)"
    else
      value
    end
  end

  @spec blank?(term()) :: boolean()
  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false
end
