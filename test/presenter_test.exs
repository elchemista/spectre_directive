defmodule SpectreDirective.PresenterTest.Custom do
  @moduledoc false

  @behaviour Spectre.Directive.Presenter

  @impl Spectre.Directive.Presenter
  def present(_boundary, opts) do
    case Keyword.get(opts, :mode, :ok) do
      :ok -> {:ok, "locale:#{Keyword.fetch!(opts, :locale)}"}
      :invalid -> :invalid
      :raise -> raise "private presenter failure"
    end
  end
end

defmodule SpectreDirective.PresenterTest do
  use ExUnit.Case, async: true

  alias Spectre.Directive.Presenter
  alias SpectreDirective.Outcome
  alias SpectreDirective.PresenterTest.Custom
  alias SpectreDirective.Request

  test "the built-in presenter handles every public conversation boundary" do
    question = %Request{kind: :question, payload: %{question: "What is your name?"}}
    confirmation = %Request{kind: :confirmation, payload: %{proposal_type: :plan}}
    policy = %Request{kind: :policy, payload: %{}}

    assert {:ok, "What is your name?"} = Presenter.call(nil, {:request, question})

    assert {:ok, "Please confirm the proposed plan."} =
             Presenter.call(nil, {:request, confirmation})

    assert {:ok, "Approval is required to continue."} =
             Presenter.call(nil, {:request, policy})

    assert {:ok, "done"} =
             Presenter.call(nil, {:outcome, %Outcome{status: :completed, result: "done"}})

    assert {:ok, "The mission could not be completed."} =
             Presenter.call(nil, {:outcome, %Outcome{status: :failed}})

    assert {:ok, "Mission cancelled."} =
             Presenter.call(nil, {:outcome, %Outcome{status: :cancelled}})
  end

  test "custom presenters merge options and normalize function replies" do
    boundary = {:outcome, %Outcome{status: :completed}}

    assert {:ok, "locale:it"} =
             Presenter.call({Custom, locale: "en"}, boundary, locale: "it")

    assert {:ok, "custom"} = Presenter.call(fn _boundary, _opts -> "custom" end, boundary)
  end

  test "custom presenter failures are contained and malformed replies are rejected" do
    boundary = {:outcome, %Outcome{status: :completed}}

    assert {:error, {:invalid_directive_presenter_reply, :atom}} =
             Presenter.call({Custom, locale: "en", mode: :invalid}, boundary)

    assert {:error, {:directive_presenter_exception, Custom, RuntimeError}} =
             Presenter.call({Custom, locale: "en", mode: :raise}, boundary)

    assert {:error, {:undefined_directive_presenter, String}} =
             Presenter.call(String, boundary)
  end
end
