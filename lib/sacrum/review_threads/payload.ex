defmodule Sacrum.ReviewThreads.Payload do
  @moduledoc "Wire payload for review-thread anchors and their current position."

  alias Sacrum.Repo.Schemas.ReviewThread

  @string_fields ~w(parent_chat_id path original_commit_id original_blob_id tool_use_id origin_ref)a
  @line_fields ~w(original_start_line original_line start_line line)a
  @boolean_fields ~w(deleted outdated_noted)a
  @enum_fields ~w(side home_kind status origin_kind)a
  @fields @string_fields ++ @line_fields ++ @boolean_fields ++ @enum_fields

  @strings Enum.map(@string_fields, &Atom.to_string/1)
  @lines Enum.map(@line_fields, &Atom.to_string/1)
  @booleans Enum.map(@boolean_fields, &Atom.to_string/1)
  @enums Map.new(@enum_fields, &{Atom.to_string(&1), Ecto.Enum.dump_values(ReviewThread, &1)})
  @nullable ~w(tool_use_id origin_ref start_line line)

  @spec fields() :: [atom()]
  def fields, do: @fields

  @spec validate(term()) :: :ok | {:error, :invalid_payload}
  def validate(payload) when is_map(payload) do
    if Enum.all?(payload, &valid_field?/1), do: :ok, else: {:error, :invalid_payload}
  end

  def validate(_), do: {:error, :invalid_payload}

  defp valid_field?({field, nil}) when field in @nullable, do: true

  defp valid_field?({field, value}) when field in @strings do
    is_binary(value) and byte_size(value) in 1..16_384 and String.valid?(value) and
      not String.contains?(value, <<0>>)
  end

  defp valid_field?({field, value}) when field in @lines,
    do: is_integer(value) and value in 1..2_147_483_647

  defp valid_field?({field, value}) when field in @booleans, do: is_boolean(value)
  defp valid_field?({field, value}), do: value in Map.get(@enums, field, [])
end
