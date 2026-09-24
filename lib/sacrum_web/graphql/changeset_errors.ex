defmodule SacrumWeb.Graphql.ChangesetErrors do
  @moduledoc """
  Formats Ecto changeset errors for GraphQL mutation error responses.
  """

  @spec format(Ecto.Changeset.t()) :: String.t()
  def format(%Ecto.Changeset{} = changeset) do
    changeset
    |> PolymorphicEmbed.traverse_errors(&format_message/1)
    |> flatten()
    |> Enum.join(", ")
  end

  # Nested embed errors read as `config.route_config: ...`.
  defp flatten(errors, prefix \\ nil) do
    Enum.flat_map(errors, fn
      {field, nested} when is_map(nested) -> flatten(nested, path(prefix, field))
      {field, messages} -> Enum.map(messages, &"#{path(prefix, field)}: #{&1}")
    end)
  end

  defp path(nil, field), do: to_string(field)
  defp path(prefix, field), do: "#{prefix}.#{field}"

  @spec format_message({String.t(), keyword()}) :: String.t()
  def format_message({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end
end
