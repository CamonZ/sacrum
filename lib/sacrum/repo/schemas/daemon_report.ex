defmodule Sacrum.Repo.Schemas.DaemonReport do
  @moduledoc """
  Small, versioned daemon report contract.

  The report is an in-memory embedded schema, not a persisted database
  record. Unknown fields are ignored; malformed values in the known contract
  are rejected.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @max_payload_bytes 32_768
  @max_string_length 256
  @max_capability_entries 32
  @max_capability_name_length 64
  @supported_versions [0, 1]
  @fields ~w(version daemon_id daemon_version os architecture host started_at capabilities)a
  @string_fields ~w(daemon_version os architecture host)a

  @primary_key false

  embedded_schema do
    field :version, :integer, default: 0
    field :daemon_id, :binary_id
    field :daemon_version, :string
    field :os, :string
    field :architecture, :string
    field :host, :string
    field :started_at, :utc_datetime_usec
    field :capabilities, :map
  end

  @type t :: %__MODULE__{}

  @type metrics :: %{
          required(:report_version) => non_neg_integer(),
          required(:daemon_version) => String.t() | nil,
          required(:os) => String.t() | nil,
          required(:architecture) => String.t() | nil,
          required(:host) => String.t() | nil,
          required(:started_at) => DateTime.t() | nil,
          required(:last_seen_at) => DateTime.t() | nil,
          required(:capabilities) => map() | nil,
          optional(:connection_status) => String.t(),
          optional(:health) => String.t(),
          optional(:health_reason) => String.t() | nil
        }

  @spec parse(term()) :: {:ok, t()} | {:error, :invalid_report}
  def parse(payload) when is_map(payload) do
    with :ok <- bounded?(payload),
         {:ok, report} <- apply_action(changeset(payload), :insert) do
      {:ok, report}
    else
      _ -> {:error, :invalid_report}
    end
  end

  def parse(_payload), do: {:error, :invalid_report}

  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs) when is_map(attrs), do: changeset(%__MODULE__{}, attrs)

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = report, attrs) when is_map(attrs) do
    report
    |> cast(attrs, @fields, empty_values: [])
    |> validate_inclusion(:version, @supported_versions)
    |> normalize_strings()
    |> validate_lengths()
    |> validate_capabilities()
  end

  @doc "Merges a report into the previous live metrics without retaining raw input."
  @spec merge_metrics(t(), metrics() | nil, boolean(), DateTime.t()) :: metrics()
  def merge_metrics(report, previous, heartbeat?, %DateTime{} = now) do
    metrics = previous || default_metrics()

    fields =
      report
      |> Map.take([:daemon_version, :os, :architecture, :host, :started_at, :capabilities])
      |> Enum.reject(fn {_field, value} -> is_nil(value) end)
      |> Map.new()

    fields =
      if heartbeat?,
        do: fields,
        else: Map.put(fields, :report_version, report.version)

    metrics
    |> Map.merge(fields)
    |> Map.put(:last_seen_at, now)
  end

  defp bounded?(payload) when map_size(payload) <= 64 do
    case Jason.encode(payload) do
      {:ok, encoded} when byte_size(encoded) <= @max_payload_bytes -> :ok
      _ -> {:error, :invalid_report}
    end
  end

  defp bounded?(_payload), do: {:error, :invalid_report}

  defp normalize_strings(changeset) do
    Enum.reduce(@string_fields, changeset, fn field, changeset ->
      update_change(changeset, field, &String.trim/1)
    end)
  end

  defp validate_lengths(changeset) do
    Enum.reduce(@string_fields, changeset, fn field, changeset ->
      changeset = validate_length(changeset, field, max: @max_string_length)
      validate_change(changeset, field, &reject_blank/2)
    end)
  end

  defp reject_blank(field, value) do
    if value == "", do: [{field, "can't be blank"}], else: []
  end

  defp validate_capabilities(changeset) do
    changeset
    |> validate_change(:capabilities, fn field, capabilities ->
      case normalize_capabilities(capabilities) do
        {:ok, _normalized} -> []
        {:error, _reason} -> [{field, "is invalid"}]
      end
    end)
    |> update_change(:capabilities, fn capabilities ->
      case normalize_capabilities(capabilities) do
        {:ok, normalized} -> normalized
        {:error, _reason} -> capabilities
      end
    end)
  end

  defp normalize_capabilities(nil), do: {:ok, nil}

  defp normalize_capabilities(capabilities) when is_map(capabilities) do
    with {:ok, providers} <- parse_group(Map.get(capabilities, "providers")),
         {:ok, harnesses} <- parse_group(Map.get(capabilities, "harnesses")) do
      result = %{}
      result = if providers, do: Map.put(result, "providers", providers), else: result
      result = if harnesses, do: Map.put(result, "harnesses", harnesses), else: result
      if result == %{}, do: {:ok, nil}, else: {:ok, result}
    end
  end

  defp normalize_capabilities(_value), do: {:error, :invalid_report}

  defp parse_group(nil), do: {:ok, nil}

  defp parse_group(group) when is_map(group) and map_size(group) <= @max_capability_entries do
    case Enum.reduce_while(group, {:ok, %{}}, &parse_capability/2) do
      {:ok, result} when map_size(result) == 0 -> {:ok, nil}
      result -> result
    end
  end

  defp parse_group(_value), do: {:error, :invalid_report}

  defp parse_capability({name, value}, {:ok, result}) do
    case {valid_name?(name), readiness(value)} do
      {true, {:ok, readiness}} -> {:cont, {:ok, Map.put(result, name, readiness)}}
      _ -> {:halt, {:error, :invalid_report}}
    end
  end

  defp valid_name?(name),
    do: is_binary(name) and name != "" and String.length(name) <= @max_capability_name_length

  defp readiness(value) when is_boolean(value), do: {:ok, value}
  defp readiness(_value), do: {:error, :invalid_report}

  defp default_metrics do
    %{
      report_version: 0,
      daemon_version: nil,
      os: nil,
      architecture: nil,
      host: nil,
      started_at: nil,
      last_seen_at: nil,
      capabilities: nil
    }
  end
end
