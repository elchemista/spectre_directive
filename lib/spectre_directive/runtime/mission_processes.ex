defmodule SpectreDirective.Runtime.MissionProcesses do
  @moduledoc """
  Process-facing API for live missions.

  `SpectreDirective` delegates to this module after an authored or emergent
  mission has been normalized into a `SpectreDirective.MissionBlueprint`.

  The module owns the small bit of OTP plumbing that should not leak into the
  public API:

  * lazily starts runtime infrastructure when the host application has not
    supervised it explicitly,
  * starts one `MissionMachine` per mission,
  * resolves either mission pids or mission ids,
  * converts missing mission ids into `{:error, :not_found}`.

  It deliberately does not contain planning logic. Planning and correction live
  in the mission machine and runtime domain modules.
  """

  alias SpectreDirective.MissionBlueprint
  alias SpectreDirective.Pulse
  alias SpectreDirective.Runtime.MissionMachine

  @doc """
  Starts a supervised runtime process for a mission blueprint.
  """
  @spec start(MissionBlueprint.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(%MissionBlueprint{} = blueprint, opts) do
    with :ok <- SpectreDirective.Runtime.Supervisor.ensure_started(runtime_opts(opts)) do
      child = {MissionMachine, Keyword.put(opts, :blueprint, blueprint)}
      DynamicSupervisor.start_child(SpectreDirective.MissionSupervisor, child)
    end
  end

  @doc """
  Returns the live pulse for a mission process or mission id.
  """
  @spec pulse(pid() | binary()) :: {:ok, Pulse.t()} | {:error, term()}
  def pulse(ref), do: call(ref, :pulse)

  @doc """
  Returns the mission trace.
  """
  @spec trace(pid() | binary()) :: {:ok, list()} | {:error, term()}
  def trace(ref), do: call(ref, :trace)

  @doc """
  Returns the current mission plan.
  """
  @spec plan(pid() | binary()) :: {:ok, SpectreDirective.Plan.t()} | {:error, term()}
  def plan(ref), do: call(ref, :plan)

  @doc """
  Returns the current mission knowledge.
  """
  @spec knowledge(pid() | binary()) :: {:ok, SpectreDirective.Knowledge.t()} | {:error, term()}
  def knowledge(ref), do: call(ref, :knowledge)

  @doc """
  Returns the discovered and authored capability snapshot.
  """
  @spec capabilities(pid() | binary()) ::
          {:ok, SpectreDirective.CapabilitySnapshot.t()} | {:error, term()}
  def capabilities(ref), do: call(ref, :capabilities)

  @doc """
  Returns the current manual guided planning state.
  """
  @spec planning_state(pid() | binary()) :: {:ok, term()} | {:error, term()}
  def planning_state(ref), do: call(ref, :planning_state)

  @doc """
  Asks the configured planner/model for one manual guided planning item.
  """
  @spec propose_plan_item(pid() | binary(), keyword()) :: {:ok, term()} | {:error, term()}
  def propose_plan_item(ref, opts \\ []), do: call(ref, {:propose_plan_item, opts})

  @doc """
  Submits a manual guided planning item from an external process.
  """
  @spec submit_plan_item(pid() | binary(), term()) :: {:ok, term()} | {:error, term()}
  def submit_plan_item(ref, proposal), do: call(ref, {:submit_plan_item, proposal})

  @doc """
  Accepts the pending manual guided planning item, optionally with edits.
  """
  @spec accept_plan_item(pid() | binary(), term()) :: {:ok, term()} | {:error, term()}
  def accept_plan_item(ref, item_or_edit \\ :pending),
    do: call(ref, {:accept_plan_item, item_or_edit})

  @doc """
  Rejects the pending manual guided planning item.
  """
  @spec reject_plan_item(pid() | binary(), term()) :: {:ok, term()} | {:error, term()}
  def reject_plan_item(ref, reason), do: call(ref, {:reject_plan_item, reason})

  @doc """
  Finishes manual guided planning and starts execution.
  """
  @spec finish_planning(pid() | binary(), term()) :: {:ok, Pulse.t()} | {:error, term()}
  def finish_planning(ref, reason \\ nil), do: call(ref, {:finish_planning, reason})

  @doc """
  Returns or selects the next current step.
  """
  @spec next_step(pid() | binary()) :: {:ok, SpectreDirective.Step.t() | nil} | {:error, term()}
  def next_step(ref), do: call(ref, :next_step)

  @doc """
  Completes the current step with an observation.
  """
  @spec complete_step(pid() | binary(), term()) :: {:ok, Pulse.t()} | {:error, term()}
  def complete_step(ref, observation), do: call(ref, {:complete_step, observation})

  @doc """
  Applies an observation to the current step.
  """
  @spec apply_observation(pid() | binary(), term()) :: {:ok, Pulse.t()} | {:error, term()}
  def apply_observation(ref, observation), do: complete_step(ref, observation)

  @doc """
  Applies a control action to the mission.
  """
  @spec control(pid() | binary(), term()) :: {:ok, Pulse.t()} | {:error, term()}
  def control(ref, action), do: call(ref, {:control, action})

  @spec call(pid() | binary(), term()) :: {:ok, term()} | {:error, :not_found}
  defp call(ref, message) when is_pid(ref), do: :gen_statem.call(ref, message)

  defp call(ref, message) when is_binary(ref) do
    ref
    |> lookup_mission()
    |> call_mission(message)
  end

  @spec runtime_opts(keyword()) :: keyword()
  defp runtime_opts(opts), do: Keyword.get(opts, :runtime_opts, [])

  @spec lookup_mission(binary()) :: {:ok, pid()} | {:error, :not_found}
  defp lookup_mission(ref) do
    if Process.whereis(SpectreDirective.Registry) do
      case Registry.lookup(SpectreDirective.Registry, ref) do
        [{pid, _value}] -> {:ok, pid}
        [] -> {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end

  @spec call_mission({:ok, pid()} | {:error, :not_found}, term()) ::
          {:ok, term()} | {:error, :not_found}
  defp call_mission({:ok, pid}, message), do: :gen_statem.call(pid, message)
  defp call_mission({:error, :not_found}, _message), do: {:error, :not_found}
end
