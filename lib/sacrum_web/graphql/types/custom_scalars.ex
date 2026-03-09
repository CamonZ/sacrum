defmodule SacrumWeb.Graphql.Types.CustomScalars do
  @moduledoc """
  Custom scalar types for Absinthe schema.
  """

  use Absinthe.Schema.Notation

  @uuid_regex ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  @desc "UUID v4 identifier"
  scalar :uuid4, description: "UUID v4 string (e.g. 550e8400-e29b-41d4-a716-446655440000)" do
    parse(fn
      %Absinthe.Blueprint.Input.String{value: value} ->
        if Regex.match?(@uuid_regex, value), do: {:ok, value}, else: :error

      %Absinthe.Blueprint.Input.Null{} ->
        {:ok, nil}

      _ ->
        :error
    end)

    serialize(fn value -> value end)
  end

  @desc "UTC datetime with microsecond precision"
  scalar :datetime, description: "ISO 8601 datetime with microsecond precision" do
    parse(fn
      %Absinthe.Blueprint.Input.String{value: value} ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> {:ok, datetime}
          {:error, _reason} -> :error
        end

      %Absinthe.Blueprint.Input.Null{} ->
        {:ok, nil}

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
          {:error, _reason} -> :error
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
