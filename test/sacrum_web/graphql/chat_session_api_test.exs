defmodule SacrumWeb.Graphql.ChatSessionApiTest do
  use SacrumWeb.ConnCase

  alias Sacrum.Accounts
  alias Sacrum.Accounts.ChatEvents

  defp graphql(conn, query) do
    post(conn, "/graphql", %{"query" => query})
  end

  defp graphql_result(conn, user, query) do
    conn
    |> authenticate(user)
    |> graphql(query)
    |> json_response(200)
  end

  defp setup_user_and_project(_context) do
    user = create_user()
    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Chat API Project"})
    %{user: user, project: project}
  end

  describe "live chat session GraphQL API" do
    setup [:setup_user_and_project]

    test "creates, sends, queries, and cancels the current chat session", %{
      conn: conn,
      user: user,
      project: project
    } do
      create_result =
        graphql_result(conn, user, """
        mutation {
          createChatSession(projectId: "#{project.id}", sessionKind: "planning") {
            id
            projectId
            status
            sessionKind
            publicMetadata
            insertedAt
            updatedAt
          }
        }
        """)

      assert create_result["errors"] == nil
      session = create_result["data"]["createChatSession"]
      assert session["projectId"] == project.id
      assert session["status"] == "queued"
      assert session["sessionKind"] == "planning"
      assert session["publicMetadata"] == %{}

      {:ok, _internal_event} =
        ChatEvents.append(user.id, project.id, session["id"], %{
          event_type: "runner.tool_trace",
          visibility: :internal,
          public_payload: %{},
          internal_payload: %{"secret" => "hidden"}
        })

      send_result =
        graphql_result(conn, user, """
        mutation {
          sendChatMessage(
            projectId: "#{project.id}"
            chatSessionId: "#{session["id"]}"
            content: "Plan the next step"
            contentFormat: "markdown"
            clientMessageId: "client-1"
          ) {
            id
            projectId
            chatSessionId
            role
            content
            contentFormat
            clientMessageId
            metadata
          }
        }
        """)

      assert send_result["errors"] == nil
      message = send_result["data"]["sendChatMessage"]
      assert message["projectId"] == project.id
      assert message["chatSessionId"] == session["id"]
      assert message["role"] == "user"
      assert message["content"] == "Plan the next step"
      assert message["contentFormat"] == "markdown"
      assert message["clientMessageId"] == "client-1"
      assert message["metadata"] == %{}

      query_result =
        graphql_result(conn, user, """
        {
          chatSession(projectId: "#{project.id}", id: "#{session["id"]}") {
            id
            status
            messages { id content role contentFormat clientMessageId }
            events { eventType payload }
          }
          chatMessages(projectId: "#{project.id}", chatSessionId: "#{session["id"]}") {
            id
            content
            role
          }
          chatEvents(projectId: "#{project.id}", chatSessionId: "#{session["id"]}") {
            eventType
            payload
          }
        }
        """)

      assert query_result["errors"] == nil
      found_session = query_result["data"]["chatSession"]
      assert found_session["id"] == session["id"]
      assert found_session["status"] == "queued"
      assert Enum.map(found_session["messages"], & &1["id"]) == [message["id"]]
      assert Enum.map(query_result["data"]["chatMessages"], & &1["id"]) == [message["id"]]

      event_types = Enum.map(query_result["data"]["chatEvents"], & &1["eventType"])
      assert event_types == ["chat_session_created", "chat_message_created"]
      refute "runner.tool_trace" in event_types

      message_event =
        Enum.find(
          query_result["data"]["chatEvents"],
          &(&1["eventType"] == "chat_message_created")
        )

      assert message_event["payload"]["content"] == "Plan the next step"
      refute Map.has_key?(message_event["payload"], "internal_payload")
      refute Map.has_key?(message_event["payload"], "secret")

      cancel_result =
        graphql_result(conn, user, """
        mutation {
          cancelChatSession(projectId: "#{project.id}", chatSessionId: "#{session["id"]}") {
            id
            status
            stopRequestedAt
            endedAt
          }
        }
        """)

      assert cancel_result["errors"] == nil
      cancelled = cancel_result["data"]["cancelChatSession"]
      assert cancelled["id"] == session["id"]
      assert cancelled["status"] == "cancelled"
      assert is_binary(cancelled["stopRequestedAt"])
      assert is_binary(cancelled["endedAt"])

      events_after_cancel =
        graphql_result(conn, user, """
        {
          chatEvents(projectId: "#{project.id}", chatSessionId: "#{session["id"]}") {
            eventType
            payload
          }
        }
        """)

      assert events_after_cancel["errors"] == nil

      assert Enum.map(events_after_cancel["data"]["chatEvents"], & &1["eventType"]) == [
               "chat_session_created",
               "chat_message_created",
               "chat_session_updated"
             ]

      status_event =
        Enum.find(
          events_after_cancel["data"]["chatEvents"],
          &(&1["eventType"] == "chat_session_updated")
        )

      assert status_event["payload"]["status"] == "cancelled"
      assert status_event["payload"]["id"] == session["id"]
    end

    test "rejects cross-user query and mutation access", %{
      conn: conn,
      user: user,
      project: project
    } do
      other_user = create_user(%{email: "other-chat@example.com", username: "other_chat"})

      create_result =
        graphql_result(conn, user, """
        mutation {
          createChatSession(projectId: "#{project.id}") { id }
        }
        """)

      session_id = create_result["data"]["createChatSession"]["id"]

      query_result =
        graphql_result(conn, other_user, """
        {
          chatSession(projectId: "#{project.id}", id: "#{session_id}") { id }
        }
        """)

      assert query_result["data"]["chatSession"] == nil
      assert [%{"message" => _}] = query_result["errors"]

      message_result =
        graphql_result(conn, other_user, """
        mutation {
          sendChatMessage(
            projectId: "#{project.id}"
            chatSessionId: "#{session_id}"
            content: "not allowed"
          ) { id }
        }
        """)

      assert message_result["data"]["sendChatMessage"] == nil
      assert [%{"message" => _}] = message_result["errors"]

      cancel_result =
        graphql_result(conn, other_user, """
        mutation {
          cancelChatSession(projectId: "#{project.id}", chatSessionId: "#{session_id}") {
            id
          }
        }
        """)

      assert cancel_result["data"]["cancelChatSession"] == nil
      assert [%{"message" => _}] = cancel_result["errors"]

      events_result =
        graphql_result(conn, other_user, """
        {
          chatEvents(projectId: "#{project.id}", chatSessionId: "#{session_id}") {
            eventType
          }
        }
        """)

      assert events_result["data"]["chatEvents"] == nil
      assert [%{"message" => _}] = events_result["errors"]
    end
  end
end
