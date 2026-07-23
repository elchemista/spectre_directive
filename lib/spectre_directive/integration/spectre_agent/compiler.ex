defmodule SpectreDirective.Integration.SpectreAgent.Compiler do
  @moduledoc false

  alias SpectreDirective.Integration.SpectreAgent

  @options_attribute :__spectre_directive_spectre_agent_options__
  @turn_handler SpectreDirective.Integration.SpectreAgent.TurnHandler
  @integration_option_keys [
    :store,
    :store_opts,
    :store_namespace,
    :presenter,
    :presenter_opts,
    :await_timeout
  ]

  @doc false
  @spec register(module(), keyword()) :: :ok
  def register(module, opts) do
    rules = Module.get_attribute(module, :spectre_rules) |> List.wrap()

    if Enum.any?(rules, &(Map.get(&1, :label) == :__spectre_directive_reason__)) do
      raise ArgumentError, "Spectre Agent already defines :__spectre_directive_reason__"
    end

    # Spectre has already registered this accumulating attribute. Adding the
    # internal rule here lets its own before_compile hook validate and compile
    # the route exactly like an authored Agent rule.
    Module.put_attribute(module, :spectre_rules, spectre_rule())
    register_options(module, opts)
    maybe_register_turn_handler(module, opts)
    :ok
  end

  @doc false
  @spec before_compile(module()) :: Macro.t()
  def before_compile(module) do
    opts = Module.get_attribute(module, @options_attribute) || []

    definitions = [
      host_introspection(),
      maybe_start_directive(module),
      maybe_start_directive_turn(module, opts),
      maybe_reason_entry(module)
    ]

    quote do
      (unquote_splicing(definitions))
    end
  end

  @spec register_options(module(), keyword()) :: :ok
  defp register_options(module, opts) do
    Module.register_attribute(module, @options_attribute, persist: false)
    Module.put_attribute(module, @options_attribute, Keyword.take(opts, @integration_option_keys))
    :ok
  end

  @spec maybe_register_turn_handler(module(), keyword()) :: :ok
  defp maybe_register_turn_handler(module, opts) do
    case Keyword.get(opts, :store) do
      nil ->
        :ok

      _store ->
        config = Module.get_attribute(module, :spectre_config) || []

        handler_opts =
          opts |> Keyword.take(@integration_option_keys) |> Keyword.put(:owner, module)

        handler = {@turn_handler, handler_opts}

        case Keyword.get(config, :turn_handlers, []) do
          handlers when is_list(handlers) ->
            Module.put_attribute(
              module,
              :spectre_config,
              Keyword.put(config, :turn_handlers, handlers ++ [handler])
            )

            :ok

          false ->
            raise ArgumentError,
                  "use Spectre.Directive with store: requires Spectre turn handlers; " <>
                    "remove turn_handlers false"

          invalid ->
            raise ArgumentError,
                  "invalid Spectre turn_handlers before use Spectre.Directive: " <>
                    inspect(invalid)
        end
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

  @spec maybe_start_directive_turn(module(), keyword()) :: Macro.t()
  defp maybe_start_directive_turn(module, opts) do
    cond do
      is_nil(Keyword.get(opts, :store)) ->
        empty_quote()

      Module.defines?(module, {:start_directive_turn, 3}) or
          Module.defines?(module, {:start_directive_turn, 4}) ->
        empty_quote()

      true ->
        quote do
          @doc "Starts and snapshots an authored directive from one Spectre Agent turn."
          @spec start_directive_turn(binary() | atom() | nil, term(), term()) :: term()
          def start_directive_turn(name, input, spectre_context) do
            start_directive_turn(name, input, spectre_context, [])
          end

          @doc "Starts a persisted Directive conversation with per-run options."
          @spec start_directive_turn(binary() | atom() | nil, term(), term(), keyword()) :: term()
          def start_directive_turn(name, input, spectre_context, runtime_opts) do
            opts = Keyword.merge(unquote(Macro.escape(opts)), runtime_opts)

            SpectreAgent.start_turn(
              __MODULE__,
              name,
              input,
              spectre_context,
              opts
            )
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
