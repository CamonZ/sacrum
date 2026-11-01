defmodule SacrumWeb.Graphql.Middleware.ChangesetErrors do
  @moduledoc """
  Converts `%Ecto.Changeset{}` entries in `resolution.errors` into structured
  GraphQL error maps so resolvers that leak a changeset don't crash Absinthe
  with a `Protocol.UndefinedError` for `String.Chars`.

  An error added with a `:code` option (`add_error(..., code: :some_code)`)
  keeps it as the GraphQL error's `code`. Non-changeset errors pass through
  unchanged.
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
    |> Ecto.Changeset.traverse_errors(fn {_msg, opts} = error ->
      {ChangesetErrors.format_message(error), opts[:code]}
    end)
    |> flatten_errors()
  end

  defp transform(other), do: [other]

  defp flatten_errors(errors, path \\ []) do
    Enum.flat_map(errors, fn {field, messages} ->
      flatten_messages(messages, [field | path])
    end)
  end

  defp flatten_messages(messages, path) when is_map(messages), do: flatten_errors(messages, path)

  defp flatten_messages(messages, path) do
    Enum.map(messages, fn {message, code} ->
      field = path |> Enum.reverse() |> Enum.map_join(".", &to_string/1)
      error = %{message: "#{field}: #{message}", field: field}
      if code, do: Map.put(error, :code, to_string(code)), else: error
    end)
  end
end
