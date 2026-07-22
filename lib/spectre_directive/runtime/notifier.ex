defmodule SpectreDirective.Runtime.Notifier do
  @moduledoc false

  alias SpectreDirective.Loop.State, as: LoopState
  alias SpectreDirective.Request
  alias SpectreDirective.Runtime.State

  @doc false
  @spec put_loop(State.t(), LoopState.t()) :: State.t()
  def put_loop(%State{} = state, %LoopState{} = loop) do
    loop.trace
    |> Enum.drop(length(state.loop.trace))
    |> Enum.each(&event(state, :trace, &1))

    State.put_loop(state, loop)
  end

  @doc false
  @spec request(State.t(), Request.t()) :: State.t()
  def request(%State{notified_request_id: request_id} = state, %Request{id: request_id}),
    do: state

  def request(%State{} = state, %Request{} = request) do
    event(state, :request, request)
    %{state | notified_request_id: request.id}
  end

  @doc false
  @spec outcome(State.t(), term()) :: State.t()
  def outcome(%State{terminal_notified?: true} = state, _outcome), do: state

  def outcome(%State{} = state, outcome) do
    event(state, :outcome, outcome)
    %{state | terminal_notified?: true}
  end

  @doc false
  @spec event(State.t(), atom(), term()) :: :ok
  def event(%State{} = state, event, payload) do
    # Subscribers receive only the mission id and boundary payload, never the
    # complete runtime state held by the mission process.
    Enum.each(state.subscribers, fn subscriber ->
      send(subscriber, {:spectre_directive, state.loop.mission.id, event, payload})
    end)

    :ok
  end

  @doc false
  @spec current_boundary(pid(), LoopState.t()) :: :ok
  def current_boundary(subscriber, %LoopState{pending_request: %Request{} = request}) do
    send(subscriber, {:spectre_directive, request.mission_id, :request, request})
    :ok
  end

  def current_boundary(subscriber, %LoopState{outcome: outcome, mission: mission})
      when not is_nil(outcome) do
    send(subscriber, {:spectre_directive, mission.id, :outcome, outcome})
    :ok
  end

  def current_boundary(_subscriber, %LoopState{}), do: :ok
end
