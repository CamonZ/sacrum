defmodule Sacrum.Realtime.Cdc.NotificationProjectionTest do
  use Sacrum.DataCase, async: true

  import Sacrum.CdcAssertions

  alias Sacrum.Realtime.Cdc.Projector

  @markdown "Task [Ship it](vtb://task/3f1d9f6e-5c1b-4f8e-9f55-0b6f0c7d2a11) has completed."

  test "projects committed notifications to their project topic only" do
    project_id = Ecto.UUID.generate()
    other_project_id = Ecto.UUID.generate()
    record = notification_record(project_id)

    :ok = subscribe_project(project_id)
    :ok = subscribe_project(other_project_id)

    assert {:ok, [%{event: "notification_created", project_id: ^project_id}]} =
             Projector.project_events(event(:insert, record))

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "project:" <> ^project_id,
      event: "notification_created",
      payload: payload
    }

    assert payload == %{
             schema_version: 1,
             id: record["id"],
             project_id: project_id,
             message: @markdown,
             severity: "success",
             inserted_at: record["inserted_at"],
             read_at: nil
           }

    refute_receive %Phoenix.Socket.Broadcast{topic: "project:" <> ^other_project_id}
  end

  test "projects read updates as complete replacements" do
    project_id = Ecto.UUID.generate()
    read_at = DateTime.utc_now()
    record = Map.put(notification_record(project_id), "read_at", read_at)
    notification_id = record["id"]

    :ok = subscribe_project(project_id)

    assert {:ok, [%{event: "notification_updated"}]} =
             Projector.project_events(%WalEx.Event{
               type: :update,
               source: %WalEx.Event.Source{table: "notifications"},
               new_record: record,
               old_record: Map.put(record, "read_at", nil),
               changes: %{}
             })

    assert_receive %Phoenix.Socket.Broadcast{
      event: "notification_updated",
      payload: %{id: ^notification_id, message: @markdown, read_at: ^read_at}
    }
  end

  test "projects notification deletes as tombstones" do
    project_id = Ecto.UUID.generate()
    record = notification_record(project_id)
    notification_id = record["id"]

    :ok = subscribe_project(project_id)

    assert {:ok, [%{event: "notification_deleted"}]} =
             Projector.project_events(event(:delete, record))

    assert_receive %Phoenix.Socket.Broadcast{
      event: "notification_deleted",
      payload: %{id: ^notification_id, message: @markdown}
    }
  end

  defp event(:insert, record) do
    %WalEx.Event{
      type: :insert,
      source: %WalEx.Event.Source{table: "notifications"},
      new_record: record
    }
  end

  defp event(:delete, record) do
    %WalEx.Event{
      type: :delete,
      source: %WalEx.Event.Source{table: "notifications"},
      old_record: record
    }
  end

  defp notification_record(project_id) do
    %{
      "id" => Ecto.UUID.generate(),
      "user_id" => Ecto.UUID.generate(),
      "project_id" => project_id,
      "message" => @markdown,
      "severity" => "success",
      "inserted_at" => DateTime.utc_now(),
      "read_at" => nil
    }
  end
end
