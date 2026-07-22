defmodule SpectreDirective.Information do
  @moduledoc """
  One piece of mission-local information.

  Information belongs to the current mission run. It can come from the host,
  an invocation, a user answer, or a reasoner result. SpectreDirective does not
  recall, persist, or search it after the run.
  """

  alias SpectreDirective.ID

  @type trust :: :trusted | :untrusted | :unknown

  @type t :: %__MODULE__{
          id: binary(),
          content: term(),
          source: term(),
          step_id: binary() | nil,
          trust: trust(),
          metadata: map(),
          inserted_at: DateTime.t()
        }

  defstruct [:id, :content, :source, :step_id, :inserted_at, trust: :unknown, metadata: %{}]

  @doc "Builds mission-local information from any Elixir term."
  @spec new(term(), keyword()) :: t()
  def new(content, opts \\ [])

  def new(%__MODULE__{} = information, opts) do
    %{
      information
      | source: Keyword.get(opts, :source, information.source),
        step_id: Keyword.get(opts, :step_id, information.step_id),
        trust: Keyword.get(opts, :trust, information.trust),
        metadata: Map.merge(information.metadata, Map.new(Keyword.get(opts, :metadata, %{})))
    }
  end

  def new(content, opts) when is_list(opts) do
    %__MODULE__{
      id: Keyword.get(opts, :id) || ID.new("info"),
      content: content,
      source: Keyword.get(opts, :source, :application),
      step_id: Keyword.get(opts, :step_id),
      trust: Keyword.get(opts, :trust, :unknown),
      metadata: Map.new(Keyword.get(opts, :metadata, %{})),
      inserted_at: Keyword.get(opts, :inserted_at) || DateTime.utc_now()
    }
  end
end
