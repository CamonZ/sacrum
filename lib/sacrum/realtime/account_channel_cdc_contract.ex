defmodule Sacrum.Realtime.AccountChannelCdcContract do
  @moduledoc """
  Contract for the account-scoped daemon fleet event stream.

  Clients subscribe through the public `accounts:me` channel alias. The
  `topic/1` helper returns the authenticated user's internal
  `account:<user_id>` routing topic and must not be exposed as a client join
  topic.

  The lifecycle stream is a projection of daemon identity rows. Credential and
  raw report fields are not part of it. Live daemon metrics use a separate
  non-replayed account event and remain in connection memory only. All payload
  keys are explicit allowlists so token plaintext, token hashes, executable
  paths, project data, and future secret fields cannot leak through realtime
  serialization.
  """

  @event_names ~w(daemon_created daemon_updated daemon_deleted)
  @schema_version 1

  @daemon_row_fields ~w(id status name max_concurrency enrolled_at inserted_at updated_at)a

  @daemon_payload_keys @daemon_row_fields ++ ~w(display_name)a
  @metrics_event_name "daemon_metrics"
  @metrics_payload_keys ~w(
    id report_version daemon_version os architecture host started_at last_seen_at capabilities
    connection_status health health_reason
  )a

  @daemon_source_image_fields [:user_id | @daemon_row_fields]
  @daemon_event_payload_keys [:schema_version | @daemon_payload_keys]

  @contracts [
    %{
      event: "daemon_created",
      classification: :entity_projection,
      source_changes: [
        %{table: "daemons", operation: :insert, after_image_fields: @daemon_source_image_fields}
      ],
      payload_keys: @daemon_event_payload_keys,
      schema_version: @schema_version,
      completeness: "Complete sanitized daemon identity projection for the owner's fleet store.",
      additional_source_changes: []
    },
    %{
      event: "daemon_updated",
      classification: :entity_projection,
      source_changes: [
        %{
          table: "daemons",
          operation: :update,
          before_image_fields: @daemon_source_image_fields,
          after_image_fields: @daemon_source_image_fields
        }
      ],
      payload_keys: @daemon_event_payload_keys,
      schema_version: @schema_version,
      completeness:
        "Complete sanitized replacement identity projection for the owner's fleet store.",
      additional_source_changes: []
    },
    %{
      event: "daemon_deleted",
      classification: :entity_projection,
      source_changes: [
        %{table: "daemons", operation: :delete, before_image_fields: @daemon_source_image_fields}
      ],
      payload_keys: @daemon_event_payload_keys,
      schema_version: @schema_version,
      completeness: "Sanitized daemon identity tombstone for hard deletes.",
      additional_source_changes: []
    }
  ]

  @spec topic(String.t()) :: String.t()
  def topic(user_id), do: "account:#{user_id}"

  @spec event_names() :: [String.t()]
  def event_names, do: @event_names

  @spec contracts() :: [map()]
  def contracts, do: @contracts

  @spec contract_for(String.t()) :: {:ok, map()} | {:error, :unknown_event}
  def contract_for(event) when is_binary(event) do
    case Enum.find(@contracts, &(&1.event == event)) do
      nil -> {:error, :unknown_event}
      contract -> {:ok, contract}
    end
  end

  @spec event?(String.t()) :: boolean()
  def event?(event), do: event in @event_names

  @spec payload_keys() :: [atom()]
  def payload_keys, do: @daemon_event_payload_keys

  @spec source_image_fields() :: [atom()]
  def source_image_fields, do: @daemon_source_image_fields

  @spec metrics_event_name() :: String.t()
  def metrics_event_name, do: @metrics_event_name

  @spec metrics_payload_keys() :: [atom()]
  def metrics_payload_keys, do: [:schema_version | @metrics_payload_keys]
end
