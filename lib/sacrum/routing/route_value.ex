defmodule Sacrum.Routing.RouteValue do
  @moduledoc """
  Exact value comparison shared by route evaluation and static validation.

  Numbers compare as `Decimal`s, so an integer and a float with the same
  value are equal (`1` and `1.0`) and large integers never lose precision
  against floats. A float is read as its shortest round-trip decimal, which
  is the value its JSON text wrote. Other values compare structurally.
  """

  @spec equal?(term(), term()) :: boolean()
  def equal?(left, right) when is_number(left) and is_number(right),
    do: Decimal.eq?(decimal(left), decimal(right))

  def equal?(left, right), do: left === right

  @spec member?(term(), [term()]) :: boolean()
  def member?(value, values), do: Enum.any?(values, &equal?(value, &1))

  @spec compare(term(), term()) :: :lt | :eq | :gt
  def compare(left, right) when is_number(left) and is_number(right),
    do: Decimal.compare(decimal(left), decimal(right))

  def compare(left, right) do
    cond do
      left === right -> :eq
      left < right -> :lt
      true -> :gt
    end
  end

  # `:nin` is negated `:in`, produced when the overlap analysis pushes `not`
  # onto a predicate.
  @spec holds?(atom(), term(), term()) :: boolean()
  def holds?(:eq, actual, expected), do: equal?(actual, expected)
  def holds?(:neq, actual, expected), do: not equal?(actual, expected)
  def holds?(:in, actual, expected), do: member?(actual, expected)
  def holds?(:nin, actual, expected), do: not member?(actual, expected)
  def holds?(:lt, actual, expected), do: compare(actual, expected) == :lt
  def holds?(:lte, actual, expected), do: compare(actual, expected) != :gt
  def holds?(:gt, actual, expected), do: compare(actual, expected) == :gt
  def holds?(:gte, actual, expected), do: compare(actual, expected) != :lt

  defp decimal(value) when is_integer(value), do: Decimal.new(value)
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)
end
