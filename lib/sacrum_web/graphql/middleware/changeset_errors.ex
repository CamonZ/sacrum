defmodule SacrumWeb.Graphql.Middleware.ChangesetErrors do
  @moduledoc """
  Converts `%Ecto.Changeset{}` entries in `resolution.errors` into structured
  GraphQL error maps so resolvers that leak a changeset don't crash Absinthe
  with a `Protocol.UndefinedError` for `String.Chars`.

  Non-changeset errors pass through unchanged.
  """

  @behaviour Absinthe.Middleware

  alias SacrumWeb.Graphql.ChangesetErrors

  @impl true
  def call(%Absinthe.Resolution{errors: []} = resolution, _config), do: resolution

  def call(%Absinthe.Resolution{errors: errors} = resolution, _config) do
    %{resolution | errors: Enum.flat_map(errors, &transform/1)}
  end

  defp transform(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&ChangesetErrors.format_message/1)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, fn message ->
        %{message: "#{field}: #{message}", field: to_string(field)}
      end)
    end)
  end

  defp transform(other), do: [other]
end
