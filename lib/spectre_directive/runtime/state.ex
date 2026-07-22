defmodule SpectreDirective.Runtime.State do
  @moduledoc false

  alias SpectreDirective.Loop.State, as: LoopState

  @type execution :: :auto | :manual | {:handler, term()}

  @type t :: %__MODULE__{
          loop: LoopState.t(),
          task: Task.t() | nil,
          task_request_id: binary() | nil,
          timer_ref: reference() | nil,
          subscribers: MapSet.t(pid()),
          execution: execution(),
          request_handler: term(),
          policy_handler: term(),
          request_timeout: timeout(),
          notified_request_id: binary() | nil,
          terminal_notified?: boolean()
        }

  defstruct [
    :loop,
    :task,
    :task_request_id,
    :timer_ref,
    :request_handler,
    :policy_handler,
    execution: :auto,
    subscribers: MapSet.new(),
    request_timeout: 30_000,
    notified_request_id: nil,
    terminal_notified?: false
  ]

  @doc false
  @spec new(LoopState.t(), keyword()) :: t()
  def new(%LoopState{} = loop, opts) do
    %__MODULE__{
      loop: loop,
      subscribers:
        opts
        |> Keyword.get(:subscribers, [])
        |> List.wrap()
        |> Enum.filter(&is_pid/1)
        |> MapSet.new(),
      execution: normalize_execution(Keyword.get(opts, :execution, :auto)),
      request_handler: Keyword.get(opts, :request_handler),
      policy_handler: Keyword.get(opts, :policy_handler) || Keyword.get(opts, :policy),
      request_timeout: normalize_timeout(Keyword.get(opts, :request_timeout, 30_000))
    }
  end

  @doc false
  @spec put_loop(t(), LoopState.t()) :: t()
  def put_loop(%__MODULE__{} = state, %LoopState{} = loop), do: %{state | loop: loop}

  @spec normalize_execution(term()) :: execution()
  defp normalize_execution(mode) when mode in [:auto, :manual], do: mode
  defp normalize_execution({:handler, target}) when not is_nil(target), do: {:handler, target}
  defp normalize_execution(_mode), do: :manual

  @spec normalize_timeout(term()) :: timeout()
  defp normalize_timeout(:infinity), do: :infinity
  defp normalize_timeout(value) when is_integer(value) and value > 0, do: value
  defp normalize_timeout(_value), do: 30_000
end
