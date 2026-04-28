defimpl SpectreDirective.Job, for: Any do
  @moduledoc false

  @spec describe(term()) :: map()
  def describe(job) do
    %{
      type: inspect(job.__struct__),
      capability: "unknown job",
      risk: :unknown,
      required_fields: [],
      expected_output: "job-specific result"
    }
  rescue
    _ -> %{type: inspect(job), capability: "unknown job", risk: :unknown}
  end

  @spec validate(term(), map()) :: {:error, :unsupported_job}
  def validate(_job, _context), do: {:error, :unsupported_job}

  @spec isolation(term(), map()) :: %{mode: :unsupported}
  def isolation(_job, _context), do: %{mode: :unsupported}

  @spec run(term(), map()) :: {:error, :unsupported_job}
  def run(_job, _context), do: {:error, :unsupported_job}

  @spec cancel(term(), map()) :: :ok
  def cancel(_job, _context), do: :ok
end
