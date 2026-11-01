defmodule SacrumWeb.Graphql.ChangesetErrors do
  @moduledoc """
  Formats Ecto changeset errors for GraphQL mutation error responses.

  A validation that needs a machine-readable code adds it as error metadata
  (`add_error(changeset, field, message, code: :some_code)`); `to_error/1`
  surfaces it as the GraphQL error's `code`.
  """

  @spec format(Ecto.Changeset.t()) :: String.t()
  def format(%Ecto.Changeset{} = changeset) do
    changeset
    |> PolymorphicEmbed.traverse_errors(&format_message/1)
    |> flatten()
    |> Enum.join(", ")
  end

  @doc """
  Builds a GraphQL error map: the formatted message, plus the `code` of the
  first error that carries one.
  """
  @spec to_error(Ecto.Changeset.t()) :: %{
          required(:message) => String.t(),
          optional(:code) => String.t()
        }
  def to_error(%Ecto.Changeset{} = changeset) do
    error = %{message: format(changeset)}

    case changeset |> PolymorphicEmbed.traverse_errors(&code/1) |> flatten_codes() do
      [code | _] -> Map.put(error, :code, code)
      [] -> error
    end
  end

  defp code({_msg, opts}), do: opts[:code] && to_string(opts[:code])

  defp flatten_codes(errors) do
    errors
    |> Enum.sort_by(fn {field, _} -> to_string(field) end)
    |> Enum.flat_map(fn
      {_field, nested} when is_map(nested) -> flatten_codes(nested)
      {_field, codes} -> Enum.reject(codes, &is_nil/1)
    end)
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
