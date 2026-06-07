defmodule SpectreDirectiveCatalogTest do
  use ExUnit.Case

  alias SpectreDirective.Alignment
  alias SpectreDirective.Correction.Catalog
  alias SpectreDirective.Strategies

  test "strategy and correction catalogs expose concept vocabulary" do
    assert :observe_before_act in Strategies.primitive()
    assert :hiring_fit in Map.keys(Strategies.presets())
    assert :finish_early in Catalog.types()
    assert :drift in Catalog.strategies()
    assert :mission_relevance in Alignment.checks()
  end
end
