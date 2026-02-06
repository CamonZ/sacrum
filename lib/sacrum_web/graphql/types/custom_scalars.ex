defmodule SacrumWeb.Graphql.Types.CustomScalars do
  @moduledoc """
  Custom scalar types for Absinthe schema.
  """

  use Absinthe.Schema.Notation

  @desc "UTC datetime with microsecond precision"
  scalar :datetime, description: "ISO 8601 datetime with microsecond precision" do
    parse(fn
      %Absinthe.Blueprint.Input.String{value: value} ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> {:ok, datetime}
          :error -> :error
        end

      null when is_nil(null) ->
        {:ok, nil}

      _ ->
        :error
    end)

    serialize(fn
      %DateTime{} = value -> DateTime.to_iso8601(value)
      nil -> nil
      _ -> :error
    end)
  end

  @desc "JSON scalar for arbitrary map data"
  scalar :json, description: "Arbitrary JSON object" do
    parse(fn
      %Absinthe.Blueprint.Input.String{value: value} ->
        case Jason.decode(value) do
          {:ok, decoded} -> {:ok, decoded}
          :error -> :error
        end

      null when is_nil(null) ->
        {:ok, nil}

      _ ->
        :error
    end)

    serialize(fn
      value when is_map(value) -> value
      nil -> nil
      _ -> :error
    end)
  end

  @desc "Decimal scalar for financial values"
  scalar :decimal, description: "Decimal number" do
    parse(fn
      %Absinthe.Blueprint.Input.String{value: value} ->
        case Decimal.parse(value) do
          {decimal, ""} -> {:ok, decimal}
          _ -> :error
        end

      %Absinthe.Blueprint.Input.Float{value: value} ->
        {:ok, Decimal.from_float(value)}

      null when is_nil(null) ->
        {:ok, nil}

      _ ->
        :error
    end)

    serialize(fn
      %Decimal{} = value -> Decimal.to_string(value)
      nil -> nil
      _ -> :error
    end)
  end
end
