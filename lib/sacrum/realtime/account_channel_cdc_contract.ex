defmodule Sacrum.Realtime.AccountChannelCdcContract do
  @moduledoc """
  Contract for the account-scoped daemon fleet event stream.

  The stream is deliberately a projection of `daemons` rows only. Credential
  rows are not part of this contract, and the payload keys are an explicit
  allowlist so token plaintext, token hashes, and future secret fields cannot
  leak through realtime serialization.
  """

  @event_names ~w(daemon_created daemon_updated daemon_deleted)
  @schema_version 1

  @daemon_payload_keys ~w(
    id status name display_name max_concurrency enrolled_at inserted_at updated_at
  )a

  @daemon_source_image_fields [:user_id | @daemon_payload_keys -- [:display_name]]
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
      completeness: "Complete sanitized daemon identity projection for the owner's fleet store."
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
      completeness: "Complete sanitized replacement projection for the owner's fleet store."
    },
    %{
      event: "daemon_deleted",
      classification: :entity_projection,
      source_changes: [
        %{table: "daemons", operation: :delete, before_image_fields: @daemon_source_image_fields}
      ],
      payload_keys: @daemon_event_payload_keys,
      schema_version: @schema_version,
      completeness: "Sanitized daemon identity tombstone for hard deletes."
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
end
