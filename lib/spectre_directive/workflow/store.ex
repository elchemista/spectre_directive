defmodule SpectreDirective.WorkflowStore do
  @moduledoc """
  Caches the last known good Directive workflow and reloads it when the file changes.
  """

  use GenServer
  require Logger

  alias SpectreDirective.Workflow
  alias SpectreDirective.WorkflowStore.State

  @poll_interval_ms 1_000

  @doc """
  Starts the workflow cache process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the last known good workflow.
  """
  @spec current() :: {:ok, Workflow.loaded()} | {:error, term()}
  def current do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(pid, :current)
      _ -> Workflow.load()
    end
  end

  @doc """
  Attempts to reload the workflow file immediately.
  """
  @spec force_reload() :: :ok | {:error, term()}
  def force_reload do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(pid, :force_reload)
      _ -> :ok
    end
  end

  @impl true
  @doc false
  @spec init(keyword()) :: {:ok, State.t()}
  def init(_opts) do
    case load_state(Workflow.workflow_file_path()) do
      {:ok, state} ->
        schedule_poll()
        {:ok, state}

      {:error, reason} ->
        Logger.debug(
          "Directive workflow store starting without workflow file: #{inspect(reason)}"
        )

        schedule_poll()

        {:ok,
         %State{
           path: Workflow.workflow_file_path(),
           stamp: nil,
           workflow: %{config: %{}, prompt: "", prompt_template: ""}
         }}
    end
  end

  @impl true
  @doc false
  @spec handle_call(:current | :force_reload, GenServer.from(), State.t()) ::
          {:reply, {:ok, Workflow.loaded()} | :ok | {:error, term()}, State.t()}
  def handle_call(:current, _from, state) do
    case reload_state(state) do
      {:ok, new_state} -> {:reply, {:ok, new_state.workflow}, new_state}
      {:error, _reason, new_state} -> {:reply, {:ok, new_state.workflow}, new_state}
    end
  end

  def handle_call(:force_reload, _from, state) do
    case reload_state(state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason, new_state} -> {:reply, {:error, reason}, new_state}
    end
  end

  @impl true
  @doc false
  @spec handle_info(:poll, State.t()) :: {:noreply, State.t()}
  def handle_info(:poll, state) do
    schedule_poll()

    case reload_state(state) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, _reason, new_state} -> {:noreply, new_state}
    end
  end

  @spec schedule_poll() :: reference()
  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end

  @spec reload_state(State.t()) :: {:ok, State.t()} | {:error, term(), State.t()}
  defp reload_state(%State{} = state) do
    path = Workflow.workflow_file_path()

    if path != state.path do
      reload_path(path, state)
    else
      reload_current_path(path, state)
    end
  end

  @spec reload_current_path(Path.t(), State.t()) :: {:ok, State.t()} | {:error, term(), State.t()}
  defp reload_current_path(path, state) do
    case current_stamp(path) do
      {:ok, stamp} when stamp == state.stamp -> {:ok, state}
      {:ok, _stamp} -> reload_path(path, state)
      {:error, reason} -> {:error, reason, state}
    end
  end

  @spec reload_path(Path.t(), State.t()) :: {:ok, State.t()} | {:error, term(), State.t()}
  defp reload_path(path, state) do
    case load_state(path) do
      {:ok, new_state} ->
        {:ok, new_state}

      {:error, reason} ->
        Logger.debug(
          "Failed to reload Directive workflow path=#{path}: #{inspect(reason)}; keeping last known good config"
        )

        {:error, reason, state}
    end
  end

  @spec load_state(Path.t()) :: {:ok, State.t()} | {:error, term()}
  defp load_state(path) do
    with {:ok, workflow} <- Workflow.load(path),
         {:ok, stamp} <- current_stamp(path) do
      {:ok, %State{path: path, stamp: stamp, workflow: workflow}}
    end
  end

  @spec current_stamp(Path.t()) :: {:ok, term()} | {:error, term()}
  defp current_stamp(path) do
    with {:ok, stat} <- File.stat(path, time: :posix),
         {:ok, content} <- File.read(path) do
      {:ok, {stat.mtime, stat.size, :erlang.phash2(content)}}
    end
  end
end
