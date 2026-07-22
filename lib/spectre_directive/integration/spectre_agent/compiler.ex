defmodule SpectreDirective.Integration.SpectreAgent.Compiler do
  @moduledoc false

  alias SpectreDirective.Integration.SpectreAgent

  @doc false
  @spec register(module()) :: :ok
  def register(module) do
    rules = Module.get_attribute(module, :spectre_rules) |> List.wrap()

    if Enum.any?(rules, &(Map.get(&1, :label) == :__spectre_directive_reason__)) do
      raise ArgumentError, "Spectre Agent already defines :__spectre_directive_reason__"
    end

    # Spectre has already registered this accumulating attribute. Adding the
    # internal rule here lets its own before_compile hook validate and compile
    # the route exactly like an authored Agent rule.
    Module.put_attribute(module, :spectre_rules, spectre_rule())
    :ok
  end

  @doc false
  @spec before_compile(module()) :: Macro.t()
  def before_compile(module) do
    definitions = [
      host_introspection(),
      maybe_start_directive(module),
      maybe_reason_entry(module)
    ]

    quote do
      (unquote_splicing(definitions))
    end
  end

  @spec spectre_rule() :: map()
  defp spectre_rule do
    %{
      label: :__spectre_directive_reason__,
      flow: :__spectre_directive__,
      handler: {:run, :__spectre_directive_reason__, []},
      regex: [~r/^__spectre_directive_reason__$/],
      bag: [],
      jaro: [],
      embedding: [],
      cache: false,
      learn: false,
      checks: [spectre_directive_internal: true],
      via: [:regex],
      global?: true,
      injections: [],
      opts: []
    }
  end

  @spec maybe_start_directive(module()) :: Macro.t()
  defp maybe_start_directive(module) do
    if Module.defines?(module, {:start_directive, 1}) or
         Module.defines?(module, {:start_directive, 2}) do
      empty_quote()
    else
      quote do
        @doc "Starts one authored directive through this Spectre Agent."
        @spec start_directive(binary() | atom() | nil) :: {:ok, pid()} | {:error, term()}
        def start_directive(name), do: start_directive(name, [])

        @doc "Starts one authored directive with per-run runtime options."
        @spec start_directive(binary() | atom() | nil, keyword()) ::
                {:ok, pid()} | {:error, term()}
        def start_directive(name, opts) do
          SpectreAgent.start(__MODULE__, name, opts)
        end
      end
    end
  end

  @spec maybe_reason_entry(module()) :: Macro.t()
  defp maybe_reason_entry(module) do
    if Module.defines?(module, {:__spectre_directive_reason__, 2}) do
      empty_quote()
    else
      quote do
        @doc false
        @spec __spectre_directive_reason__(term(), term()) :: term()
        def __spectre_directive_reason__(input, spectre_context) do
          SpectreAgent.handle_turn(__MODULE__, input, spectre_context)
        end
      end
    end
  end

  @spec host_introspection() :: Macro.t()
  defp host_introspection do
    quote do
      @doc false
      @spec __spectre_directive_host__() :: :spectre_agent
      def __spectre_directive_host__, do: :spectre_agent
    end
  end

  @spec empty_quote() :: Macro.t()
  defp empty_quote, do: quote(do: nil)
end
