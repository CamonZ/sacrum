defmodule Sacrum.Realtime.Cdc.DaemonProjectionTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Realtime.AccountChannelCdcContract
  alias Sacrum.Realtime.Cdc.Projector

  test "projects daemon row images to an owner's account topic without secrets" do
    user_id = Ecto.UUID.generate()
    daemon_id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    record = daemon_record(user_id, daemon_id, "pending", "Fleet bot", now)
    :ok = Phoenix.PubSub.subscribe(Sacrum.PubSub, AccountChannelCdcContract.topic(user_id))

    assert {:ok, [%{event: "daemon_created", project_id: ^user_id, status: :dispatched}]} =
             Projector.project_events(event(:insert, record, nil))

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "account:" <> ^user_id,
      event: "daemon_created",
      payload: payload
    }

    assert payload.id == daemon_id
    assert payload.status == "pending"
    assert payload.name == "Fleet bot"
    assert payload.display_name == "Fleet bot"
    assert payload.schema_version == 1
    refute Map.has_key?(payload, :user_id)
    refute Map.has_key?(payload, :token_hash)
    refute Map.has_key?(payload, :credential)

    assert Map.keys(payload) |> Enum.sort() ==
             AccountChannelCdcContract.payload_keys() |> Enum.sort()
  end

  test "projects renamed daemon updates as the same sanitized replacement" do
    user_id = Ecto.UUID.generate()
    daemon_id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    :ok = Phoenix.PubSub.subscribe(Sacrum.PubSub, AccountChannelCdcContract.topic(user_id))

    record = daemon_record(user_id, daemon_id, "pending", "Renamed bot", now)
    record = Map.put(record, "token_hash", "never-project-this")

    assert {:ok, [%{event: "daemon_updated", project_id: ^user_id, status: :dispatched}]} =
             Projector.project_events(
               event(:update, record, daemon_record(user_id, daemon_id, "pending", nil, now))
             )

    assert_receive %Phoenix.Socket.Broadcast{
      event: "daemon_updated",
      payload: %{status: "pending", name: "Renamed bot", display_name: "Renamed bot"}
    }

    refute_received %Phoenix.Socket.Broadcast{event: "daemon_revoked"}
  end

  test "projects hard deletes from the daemon before image" do
    user_id = Ecto.UUID.generate()
    daemon_id = Ecto.UUID.generate()
    now = DateTime.utc_now()
    record = daemon_record(user_id, daemon_id, "pending", "Deleted bot", now)

    :ok = Phoenix.PubSub.subscribe(Sacrum.PubSub, AccountChannelCdcContract.topic(user_id))

    assert {:ok, [%{event: "daemon_deleted", project_id: ^user_id, status: :dispatched}]} =
             Projector.project_events(event(:delete, nil, record))

    assert_receive %Phoenix.Socket.Broadcast{
      event: "daemon_deleted",
      payload: %{id: ^daemon_id, status: "pending", name: "Deleted bot"}
    }
  end

  defp event(:insert, new_record, _old_record) do
    %WalEx.Event{
      type: :insert,
      source: %WalEx.Event.Source{table: "daemons"},
      new_record: new_record
    }
  end

  defp event(:update, new_record, old_record) do
    %WalEx.Event{
      type: :update,
      source: %WalEx.Event.Source{table: "daemons"},
      new_record: new_record,
      old_record: old_record,
      changes: %{}
    }
  end

  defp event(:delete, _new_record, old_record) do
    %WalEx.Event{
      type: :delete,
      source: %WalEx.Event.Source{table: "daemons"},
      old_record: old_record
    }
  end

  defp daemon_record(user_id, daemon_id, status, name, now) do
    %{
      "id" => daemon_id,
      "user_id" => user_id,
      "status" => status,
      "name" => name,
      "enrolled_at" => nil,
      "inserted_at" => now,
      "updated_at" => now,
      "token_hash" => "ignored-secret"
    }
  end
end
