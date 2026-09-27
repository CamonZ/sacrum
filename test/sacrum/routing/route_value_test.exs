defmodule Sacrum.Routing.RouteValueTest do
  use ExUnit.Case, async: true

  alias Sacrum.Routing.RouteValue

  test "integers and floats with the same value are equal" do
    assert RouteValue.equal?(1, 1.0)
    assert RouteValue.member?(1.0, [2, 1])
    assert RouteValue.compare(0.5, 1) == :lt
    assert RouteValue.compare(2, 2.0) == :eq
  end

  test "floats compare as their decimal text and large integers keep precision" do
    assert RouteValue.equal?(0.1, 0.1)
    assert RouteValue.compare(0.8, 0.8) == :eq
    refute RouteValue.equal?(9_007_199_254_740_993, 9_007_199_254_740_992.0)
    assert RouteValue.compare(9_007_199_254_740_993, 9_007_199_254_740_992.0) == :gt
  end

  test "non-numeric values compare structurally" do
    assert RouteValue.equal?("yes", "yes")
    refute RouteValue.equal?(true, "true")
    assert RouteValue.holds?(:nin, "maybe", ["yes", "no"])
  end
end
