defmodule SacrumWeb.Graphql.ChangesetErrors do
  @moduledoc """
  Formats Ecto changeset errors for GraphQL mutation error responses.
  """

  @spec format(Ecto.Changeset.t()) :: String.t()
  def format(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.flat_map(fn {field, errors} ->
      Enum.map(errors, &"#{field}: #{&1}")
    end)
    |> Enum.join(", ")
  end
end
