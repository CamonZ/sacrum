defmodule Sacrum.ChatCatalog.CdcTest do
  use Sacrum.DataCase, async: true
  alias Sacrum.Accounts.{ChatCatalog, Projects}
  alias Sacrum.Realtime.Cdc.Projector

  test "committed CDC row projects exact safe payload only to source owner and project" do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sacrum.Repo.Users.insert(%{
        email: "cdc-chat#{n}@example.com",
        username: "cdcchat#{n}",
        password: "password123"
      })

    {:ok, project} = Projects.insert(user.id, %{name: "CDC"})
    machine = Ecto.UUID.generate()
    {:ok, _} = ChatCatalog.register(user.id, machine)

    {:ok, %{entry: entry}} =
      ChatCatalog.put(user.id, project.id, machine, "chat", 0, Ecto.UUID.generate(), %{
        "metadata" => %{"title" => "Title"},
        "status" => "working"
      })

    SacrumWeb.Endpoint.subscribe("project:#{project.id}")
    SacrumWeb.Endpoint.subscribe("account:#{user.id}")
    SacrumWeb.Endpoint.subscribe("account:#{Ecto.UUID.generate()}")
    record = Map.from_struct(entry)

    event = %WalEx.Event{
      source: %{table: "chat_catalog_entries"},
      type: :insert,
      new_record: record
    }

    assert {:ok, [%{event: "chat_catalog_created"}]} = Projector.project_events(event)

    assert_receive %Phoenix.Socket.Broadcast{
      topic: project_topic,
      event: "chat_catalog_created",
      payload: payload
    }

    assert project_topic == "project:#{project.id}"
    assert payload.installation_id == machine
    assert payload.chat_id == "chat"
    assert payload.status == "working"
    assert payload.payload["status"] == "working"
    assert payload.payload["metadata"] == %{"title" => "Title"}
    refute Map.has_key?(payload, :user_id)

    assert_receive %Phoenix.Socket.Broadcast{
      topic: owner_topic,
      event: "chat_catalog_created",
      payload: ^payload
    }

    assert owner_topic == "account:#{user.id}"
    refute_receive %Phoenix.Socket.Broadcast{}
  end
end
