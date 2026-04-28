defmodule SpectreDirective.Workflow do
  @moduledoc """
  Loads a Directive workflow/policy file.

  This is intentionally dependency-free. It accepts Markdown with optional
  simple YAML-like front matter (`key: value`) and keeps richer parsing for
  applications that want to provide their own config layer.
  """

  @workflow_file_name "DIRECTIVE.md"

  @type loaded :: %{config: map(), prompt: binary(), prompt_template: binary()}

  @doc """
  Returns the active Directive workflow file path.
  """
  @spec workflow_file_path() :: Path.t()
  def workflow_file_path do
    Application.get_env(:spectre_directive, :workflow_file_path) ||
      Path.join(File.cwd!(), @workflow_file_name)
  end

  @doc """
  Sets the workflow file path and asks the cache to reload.
  """
  @spec set_workflow_file_path(Path.t()) :: :ok
  def set_workflow_file_path(path) when is_binary(path) do
    Application.put_env(:spectre_directive, :workflow_file_path, path)
    SpectreDirective.WorkflowStore.force_reload()
    :ok
  end

  @doc """
  Clears the configured workflow file path.
  """
  @spec clear_workflow_file_path() :: :ok
  def clear_workflow_file_path do
    Application.delete_env(:spectre_directive, :workflow_file_path)
    SpectreDirective.WorkflowStore.force_reload()
    :ok
  end

  @doc """
  Returns the current workflow, using the cache when it is running.
  """
  @spec current() :: {:ok, loaded()} | {:error, term()}
  def current do
    case Process.whereis(SpectreDirective.WorkflowStore) do
      pid when is_pid(pid) -> SpectreDirective.WorkflowStore.current()
      _ -> load()
    end
  end

  @doc """
  Loads a workflow file from disk.
  """
  @spec load(Path.t() | nil) :: {:ok, loaded()} | {:error, term()}
  def load(path \\ workflow_file_path()) do
    case File.read(path) do
      {:ok, content} -> parse(content)
      {:error, reason} -> {:error, {:missing_workflow_file, path, reason}}
    end
  end

  @doc """
  Parses workflow Markdown with optional simple front matter.
  """
  @spec parse(binary()) :: {:ok, loaded()} | {:error, term()}
  def parse(content) when is_binary(content) do
    {front_matter_lines, prompt_lines} = split_front_matter(content)

    with {:ok, config} <- parse_front_matter(front_matter_lines) do
      prompt = prompt_lines |> Enum.join("\n") |> String.trim()
      {:ok, %{config: config, prompt: prompt, prompt_template: prompt}}
    end
  end

  @spec split_front_matter(binary()) :: {[binary()], [binary()]}
  defp split_front_matter(content) do
    lines = String.split(content, ~r/\R/, trim: false)

    case lines do
      ["---" | tail] ->
        {front, rest} = Enum.split_while(tail, &(&1 != "---"))

        case rest do
          ["---" | prompt_lines] -> {front, prompt_lines}
          _ -> {front, []}
        end

      _ ->
        {[], lines}
    end
  end

  @spec parse_front_matter([binary()]) :: {:ok, map()} | {:error, term()}
  defp parse_front_matter([]), do: {:ok, %{}}

  defp parse_front_matter(lines) do
    Enum.reduce_while(lines, {:ok, %{}}, fn line, {:ok, acc} ->
      trimmed = String.trim(line)

      cond do
        trimmed == "" or String.starts_with?(trimmed, "#") ->
          {:cont, {:ok, acc}}

        String.contains?(trimmed, ":") ->
          [key, value] = String.split(trimmed, ":", parts: 2)
          {:cont, {:ok, Map.put(acc, String.trim(key), parse_scalar(String.trim(value)))}}

        true ->
          {:halt, {:error, {:workflow_parse_error, {:unsupported_front_matter_line, line}}}}
      end
    end)
  end

  @spec parse_scalar(binary()) :: binary() | boolean() | integer() | nil
  defp parse_scalar("true"), do: true
  defp parse_scalar("false"), do: false
  defp parse_scalar("nil"), do: nil
  defp parse_scalar("null"), do: nil
  defp parse_scalar("\"" <> rest), do: String.trim_trailing(rest, "\"")

  defp parse_scalar(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> value
    end
  end
end
