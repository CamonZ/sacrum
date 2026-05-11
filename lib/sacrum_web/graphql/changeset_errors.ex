defmodule SacrumWeb.Graphql.ChangesetErrors do
  @moduledoc """
  Formats Ecto changeset errors for GraphQL mutation error responses.
  """

  @spec format(Ecto.Changeset.t()) :: String.t()
  def format(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&format_message/1)
    |> Enum.flat_map(fn {field, errors} ->
      Enum.map(errors, &"#{field}: #{&1}")
    end)
    |> Enum.join(", ")
  end

  @spec format_message({String.t(), keyword()}) :: String.t()
  def format_message({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end
end
