defmodule SacrumWeb.Graphql.ShortIdErrors do
  @moduledoc """
  Formats short-ID resolver errors into human-readable GraphQL error messages.
  """

  @spec format(term(), String.t(), String.t()) :: term()
  def format({:ok, _} = ok, _entity, _prefix), do: ok

  def format({:error, :not_found}, entity, prefix),
    do: {:error, "#{entity} with prefix '#{prefix}' not found"}

  def format({:error, :invalid_prefix}, _entity, prefix),
    do: {:error, "invalid prefix '#{prefix}': must be 1-8 hexadecimal characters"}

  def format({:error, {:ambiguous, ids}}, entity, prefix),
    do:
      {:error, "ambiguous prefix '#{prefix}': multiple #{entity}s match: #{Enum.join(ids, ", ")}"}

  def format(other, _entity, _prefix), do: other
end
