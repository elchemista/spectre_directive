defmodule SpectreDirective.DSL do
  @moduledoc """
  Small authored DSL for reusable mission loops.

      defmodule ClientResearch do
        use SpectreDirective

        directive "client-research" do
          mission "Research the client"
          success "Produce a sourced client summary"
          mode :guided

          step "Read the client page" do
            purpose "Collect relevant public information"
            invoke {MyApp.ReadPage, url: "https://example.com"}
            policy :external_read
          end

          step "Produce the summary" do
            purpose "Complete the mission from collected information"
          end
        end
      end

  Anonymous invocation functions are compiled into module functions so the
  resulting blueprint remains ordinary, inspectable Elixir data.
  """

  alias SpectreDirective.DSL.Builder
  alias SpectreDirective.Integration

  @doc false
  @spec __before_compile__(Macro.Env.t()) :: Macro.t()
  defmacro __before_compile__(env) do
    directives =
      env.module
      |> Module.get_attribute(:__spectre_directives__)
      |> List.wrap()
      |> Enum.reverse()

    escaped = Macro.escape(directives)
    integration = Integration.before_compile(env)

    quote do
      @doc "Returns all directives authored by this module."
      @spec __spectre_directives__() :: [SpectreDirective.MissionBlueprint.t()]
      def __spectre_directives__, do: unquote(escaped)

      @doc "Returns one directive by name, or the first when omitted."
      @spec __spectre_directive__(binary() | atom() | nil) ::
              SpectreDirective.MissionBlueprint.t() | nil
      def __spectre_directive__(name \\ nil)
      def __spectre_directive__(nil), do: List.first(unquote(escaped))

      def __spectre_directive__(name) do
        Enum.find(unquote(escaped), &(to_string(&1.name) == to_string(name)))
      end

      unquote(integration)
    end
  end

  @doc "Defines one reusable directive."
  @spec directive(Macro.t(), keyword(Macro.t())) :: Macro.t()
  defmacro directive(name, do: block) do
    quote do
      Builder.reset_directive(__MODULE__)
      unquote(block)
      @__spectre_directives__ Builder.blueprint_from_module(__MODULE__, to_string(unquote(name)))
      Builder.reset_directive(__MODULE__)
    end
  end

  @doc "Sets the mission objective."
  @spec mission(Macro.t()) :: Macro.t()
  defmacro mission(goal), do: put(:__spectre_mission_goal__, goal)

  @doc "Alias for `mission/1`."
  @spec objective(Macro.t()) :: Macro.t()
  defmacro objective(goal), do: put(:__spectre_mission_goal__, goal)

  @doc "Adds background context to the mission."
  @spec context(Macro.t()) :: Macro.t()
  defmacro context(value), do: put(:__spectre_context__, value)

  @doc "Sets the mission's success criteria."
  @spec success(Macro.t()) :: Macro.t()
  defmacro success(value), do: put(:__spectre_success__, value)

  @doc "Sets `:fixed`, `:guided`, or `:autonomous` plan-change semantics."
  @spec mode(Macro.t()) :: Macro.t()
  defmacro mode(value), do: put(:__spectre_mode__, value)

  @doc "Sets metadata on the reusable directive."
  @spec directive_metadata(Macro.t()) :: Macro.t()
  defmacro directive_metadata(value), do: put(:__spectre_directive_metadata__, value)

  @doc "Defines a final invocation run after the reasoner completes the mission."
  @spec on_complete(Macro.t()) :: Macro.t()
  defmacro on_complete(target) do
    callback_or_value(:__spectre_on_complete__, target, __CALLER__)
  end

  @doc "Defines one authored step. A directive may omit steps and let its reasoner propose a plan."
  @spec step(Macro.t()) :: Macro.t()
  defmacro step(title) do
    quote do
      Builder.reset_step(__MODULE__)
      Builder.add_step_from_module(__MODULE__, to_string(unquote(title)))
      Builder.reset_step(__MODULE__)
    end
  end

  @doc "Defines one authored step and its attributes."
  @spec step(Macro.t(), keyword(Macro.t())) :: Macro.t()
  defmacro step(title, do: block) do
    quote do
      Builder.reset_step(__MODULE__)
      unquote(block)
      Builder.add_step_from_module(__MODULE__, to_string(unquote(title)))
      Builder.reset_step(__MODULE__)
    end
  end

  @doc "Sets the semantic step kind."
  @spec kind(Macro.t()) :: Macro.t()
  defmacro kind(value), do: put(:__spectre_step_kind__, value)

  @doc "Sets how freely a reasoner may adapt this step."
  @spec flexibility(Macro.t()) :: Macro.t()
  defmacro flexibility(value), do: put(:__spectre_step_flexibility__, value)

  @doc "Explains why the step contributes to the mission."
  @spec purpose(Macro.t()) :: Macro.t()
  defmacro purpose(value), do: put(:__spectre_step_purpose__, value)

  @doc "Explains why the step exists at this position."
  @spec reason(Macro.t()) :: Macro.t()
  defmacro reason(value), do: put(:__spectre_step_reason__, value)

  @doc "Supplies an optional prompt hint to a reasoner."
  @spec prompt(Macro.t()) :: Macro.t()
  defmacro prompt(value), do: put(:__spectre_step_prompt__, value)

  @doc "Describes the expected step output."
  @spec expects(Macro.t()) :: Macro.t()
  defmacro expects(value), do: put(:__spectre_step_expects__, value)

  @doc "Describes when the step is complete."
  @spec done_when(Macro.t()) :: Macro.t()
  defmacro done_when(value), do: put(:__spectre_step_done_when__, value)

  @doc "Labels step risk for host policy decisions."
  @spec risk(Macro.t()) :: Macro.t()
  defmacro risk(value), do: put(:__spectre_step_risk__, value)

  @doc "Sets application input for the step."
  @spec input(Macro.t()) :: Macro.t()
  defmacro input(value), do: put(:__spectre_step_input__, value)

  @doc "Sets custom step metadata."
  @spec metadata(Macro.t()) :: Macro.t()
  defmacro metadata(value), do: put(:__spectre_step_metadata__, value)

  @doc "Attaches a trusted invocation target to the step."
  @spec invoke(Macro.t()) :: Macro.t()
  defmacro invoke(target) do
    callback_or_value(:__spectre_step_invoke__, target, __CALLER__)
  end

  @doc "Attaches an opaque policy requirement checked by the host before invocation."
  @spec policy(Macro.t()) :: Macro.t()
  defmacro policy(value), do: put(:__spectre_step_policy__, value)

  @spec callback_or_value(atom(), Macro.t(), Macro.Env.t()) :: Macro.t()
  defp callback_or_value(attr, {:fn, _, _} = callback, env),
    do: compile_callback(attr, callback, env)

  defp callback_or_value(attr, {:&, _, _} = callback, env),
    do: compile_callback(attr, callback, env)

  defp callback_or_value(attr, value, _env), do: put(attr, value)

  @spec compile_callback(atom(), Macro.t(), Macro.Env.t()) :: Macro.t()
  defp compile_callback(attr, callback, env) do
    name = :"__spectre_directive_callback_#{env.line}_#{System.unique_integer([:positive])}"

    quote do
      @doc false
      def unquote(name)(context), do: unquote(callback).(context)
      Builder.put(__MODULE__, unquote(attr), {__MODULE__, unquote(name)})
    end
  end

  @spec put(atom(), Macro.t()) :: Macro.t()
  defp put(attr, value) do
    quote bind_quoted: [attr: attr, value: value] do
      Builder.put(__MODULE__, attr, value)
    end
  end
end
