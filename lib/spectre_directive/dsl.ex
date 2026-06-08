defmodule SpectreDirective.DSL do
  @moduledoc """
  Authoring macros imported by `use SpectreDirective`.

  Most users should not call this module directly. Instead:

      defmodule MyApp.Directives.Signup do
        use SpectreDirective

        directive "signup-check" do
          mission "Make sure a new user can finish sign up"
          context "Release smoke check."
          success "A test user reaches a post-signup state."

          step "Observe signup entry" do
            kind :observe
            purpose "Understand available signup paths before acting"
          end
        end
      end

  The DSL compiles authored directives into `SpectreDirective.MissionBlueprint`
  structs. Compile-time validation requires mission, context, success criteria,
  and at least one purposeful step.
  """

  alias SpectreDirective.DSL.Builder

  defmacro __before_compile__(env) do
    directives =
      env.module
      |> Module.get_attribute(:__spectre_directives__)
      |> List.wrap()
      |> Enum.reverse()

    escaped = Macro.escape(directives)

    quote do
      @doc "Returns directives authored with `use SpectreDirective`."
      @spec __spectre_directives__() :: [SpectreDirective.MissionBlueprint.t()]
      def __spectre_directives__, do: unquote(escaped)

      @doc "Returns one authored directive by name, or the first directive when no name is supplied."
      @spec __spectre_directive__(binary() | atom() | nil) ::
              SpectreDirective.MissionBlueprint.t() | nil
      def __spectre_directive__(name \\ nil)

      def __spectre_directive__(nil), do: List.first(unquote(escaped))

      def __spectre_directive__(name) do
        Enum.find(unquote(escaped), &(to_string(&1.name) == to_string(name)))
      end
    end
  end

  defmacro directive(name, do: block) do
    quote do
      Builder.reset_directive(__MODULE__)
      unquote(block)
      @__spectre_directives__ Builder.blueprint_from_module(__MODULE__, to_string(unquote(name)))
      Builder.reset_directive(__MODULE__)
    end
  end

  @doc "Sets the mission goal."
  defmacro mission(goal), do: put(:__spectre_mission_goal__, goal)
  @doc "Sets mission context, which tells the planner what matters."
  defmacro context(text), do: put(:__spectre_context__, text)
  @doc "Sets success criteria for deciding when the mission is complete enough."
  defmacro success(text), do: put(:__spectre_success__, text)
  @doc "Sets runtime mode, usually `:strict`, `:guided`, or `:adaptive`."
  defmacro mode(value), do: put(:__spectre_mode__, value)

  @doc "Groups memory hints such as `scope/1` and `remember/1`."
  defmacro memory(do: block), do: block
  @doc "Groups required, allowed, and denied capabilities."
  defmacro capabilities(do: block), do: block
  @doc "Groups strategy presets and primitive strategies."
  defmacro strategies(do: block), do: block
  @doc "Groups alignment checks."
  defmacro alignment(do: block), do: block
  @doc "Groups correction rules."
  defmacro corrections(do: block), do: block

  @doc "Sets the memory scope for recall and remember adapters."
  defmacro scope(value) do
    quote bind_quoted: [value: value] do
      Builder.put_memory(__MODULE__, :scope, value)
    end
  end

  @doc "Adds a memory category the mission should remember after steps."
  defmacro remember(value) do
    quote bind_quoted: [value: value] do
      Builder.put_memory(__MODULE__, :remember, value)
    end
  end

  @doc "Allows a capability name for this directive."
  defmacro allow(value) do
    quote bind_quoted: [value: value] do
      Builder.put_capability_rule(__MODULE__, :allowed, value)
    end
  end

  @doc "Denies a capability name even if an adapter discovers it."
  defmacro deny(value) do
    quote bind_quoted: [value: value] do
      Builder.put_capability_rule(__MODULE__, :denied, value)
    end
  end

  @doc "Marks a capability as required for the directive."
  defmacro require_capability(value) do
    quote bind_quoted: [value: value] do
      Builder.put_capability_rule(__MODULE__, :required, value)
    end
  end

  @doc "Adds a strategy preset or primitive strategy."
  defmacro strategy(strategy) do
    quote bind_quoted: [strategy: strategy] do
      Builder.add_strategy(__MODULE__, strategy)
    end
  end

  @doc "Adds an alignment check declaration."
  defmacro check(name, opts \\ []) do
    quote bind_quoted: [name: name, opts: opts] do
      Builder.add_alignment_rule(__MODULE__, {name, opts})
    end
  end

  @doc "Adds a correction rule declaration."
  defmacro on(trigger, opts) do
    quote bind_quoted: [trigger: trigger, opts: opts] do
      Builder.add_correction_rule(__MODULE__, {trigger, opts})
    end
  end

  @doc "Defines one authored step in the initial plan."
  defmacro step(title, do: block) do
    quote do
      Builder.reset_step(__MODULE__)
      unquote(block)
      Builder.add_step_from_module(__MODULE__, to_string(unquote(title)))
      Builder.reset_step(__MODULE__)
    end
  end

  @doc "Sets the step kind, such as `:observe`, `:investigate`, `:act`, or `:verify`."
  defmacro kind(value), do: put(:__spectre_step_kind__, value)

  @doc "Sets how freely the step may be adapted: `:locked`, `:guided`, `:optional`, or `:agentic`."
  defmacro flexibility(value), do: put(:__spectre_step_flexibility__, value)
  @doc "Explains why the step helps the mission."
  defmacro purpose(value), do: put(:__spectre_step_purpose__, value)
  @doc "Explains why the step exists at this point in the plan."
  defmacro reason(value), do: put(:__spectre_step_reason__, value)
  @doc "Provides an execution prompt for an agent."
  defmacro prompt(value), do: put(:__spectre_step_prompt__, value)
  @doc "Describes expected output."
  defmacro expects(value), do: put(:__spectre_step_expects__, value)
  @doc "Describes the done condition."
  defmacro done_when(value), do: put(:__spectre_step_done_when__, value)
  @doc "Sets the step risk: `:low`, `:medium`, `:high`, or `:critical`."
  defmacro risk(value), do: put(:__spectre_step_risk__, value)
  @doc "Sets the required capability for the step."
  defmacro capability(value), do: put(:__spectre_step_capability__, value)
  @doc "Sets structured input for the step."
  defmacro input(value), do: put(:__spectre_step_input__, value)
  @doc "Sets custom step metadata."
  defmacro metadata(value), do: put(:__spectre_step_metadata__, value)

  @spec put(atom(), term()) :: Macro.t()
  defp put(attr, value) do
    quote bind_quoted: [attr: attr, value: value] do
      Builder.put(__MODULE__, attr, value)
    end
  end
end
