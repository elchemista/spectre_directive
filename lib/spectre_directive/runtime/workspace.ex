defmodule SpectreDirective.Workspace do
  @moduledoc """
  Workspace preparation and path safety helpers adapted from Symphony's model.
  """

  @default_root Path.join(System.tmp_dir!(), "spectre_directive_workspaces")

  @doc """
  Returns the configured workspace root.
  """
  @spec root() :: Path.t()
  def root do
    Application.get_env(:spectre_directive, :workspace_root, @default_root)
    |> Path.expand()
  end

  @doc """
  Prepares a workspace directory under the configured or supplied root.
  """
  @spec prepare(Path.t() | nil, keyword()) :: {:ok, Path.t()} | {:error, term()}
  def prepare(cwd, opts \\ []) do
    workspace_root = opts[:root] || root()

    with {:ok, root} <- ensure_dir(Path.expand(workspace_root)),
         {:ok, path} <- resolve_path(cwd, root),
         :ok <- ensure_within_root(path, root) do
      ensure_dir(path)
    end
  end

  @doc """
  Deletes a workspace path if it stays inside the configured root.
  """
  @spec cleanup(Path.t()) :: :ok | {:error, term()}
  def cleanup(path) when is_binary(path) do
    root = root()
    expanded = Path.expand(path)

    with :ok <- ensure_within_root(expanded, root) do
      case File.rm_rf(expanded) do
        {:ok, _} -> :ok
        {:error, reason, _file} -> {:error, reason}
      end
    end
  end

  def cleanup(_path), do: :ok

  @spec resolve_path(Path.t() | nil | term(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  defp resolve_path(nil, root), do: {:ok, Path.join(root, unique_workspace_name())}
  defp resolve_path("", root), do: {:ok, Path.join(root, unique_workspace_name())}

  defp resolve_path(path, root) when is_binary(path) do
    expanded =
      if Path.type(path) == :absolute do
        Path.expand(path)
      else
        Path.expand(Path.join(root, path))
      end

    {:ok, expanded}
  end

  defp resolve_path(_path, _root), do: {:error, :invalid_workspace_path}

  @spec ensure_dir(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  defp ensure_dir(path) do
    case File.mkdir_p(path) do
      :ok -> {:ok, canonical_or_expanded(path)}
      {:error, reason} -> {:error, {:mkdir_failed, path, reason}}
    end
  end

  @spec ensure_within_root(Path.t(), Path.t()) :: :ok | {:error, term()}
  defp ensure_within_root(path, root) do
    canonical_path = canonical_or_expanded(path)
    canonical_root = canonical_or_expanded(root)
    root_prefix = canonical_root <> "/"

    cond do
      canonical_path == canonical_root ->
        :ok

      String.starts_with?(canonical_path <> "/", root_prefix) ->
        :ok

      true ->
        {:error, {:workspace_escape, canonical_path, canonical_root}}
    end
  end

  @spec canonical_or_expanded(Path.t()) :: Path.t()
  defp canonical_or_expanded(path) do
    Path.expand(path)
  end

  @spec unique_workspace_name() :: binary()
  defp unique_workspace_name do
    "task_#{System.unique_integer([:positive, :monotonic])}"
  end
end
