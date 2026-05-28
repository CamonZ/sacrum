defmodule SacrumWeb.Graphql.ChatSessionApiTest do
  use SacrumWeb.ConnCase

  alias Sacrum.Accounts
  alias Sacrum.Accounts.{Artifacts, ChatEvents, ChatSessions, LiveChat}
  alias Sacrum.Chat.{Inference.Result, PublicEvents}
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{ChatEvent, ChatMessage, ChatSession}

  import Ecto.Query

  defmodule FakeProvider do
    @behaviour Sacrum.Chat.Inference.Provider

    @impl true
    def generate(messages, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:fake_provider_called, self(), messages})

      receive do
        :release_fake_provider -> :ok
      after
        1_000 -> :ok
      end

      {:ok,
       %Result{
         content: "Assistant response from GraphQL runner",
         content_format: :markdown,
         public_metadata: %{"provider" => "fake", "model" => "graphql-test"},
         internal_metadata: %{"trace_id" => "graphql-runner-trace"}
       }}
    end
  end

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

  defp set_inserted_at!(session, inserted_at) do
    session
    |> Ecto.Changeset.change(inserted_at: inserted_at)
    |> Repo.update!()
  end

  defp configure_live_chat_runner(_context) do
    previous = Application.get_env(:sacrum, :live_chat_runner)

    Application.put_env(:sacrum, :live_chat_runner,
      start_opts: [inference_opts: [provider: FakeProvider, test_pid: self()]]
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:sacrum, :live_chat_runner, previous)
      else
        Application.delete_env(:sacrum, :live_chat_runner)
      end
    end)
  end

  describe "live chat session GraphQL API" do
    setup [:setup_user_and_project, :configure_live_chat_runner]

    test "creates, sends, queries, and completes the current chat session", %{
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

      assert_receive {:fake_provider_called, provider_pid,
                      [%{role: "system"}, %{role: "user", content: "Plan the next step"}]},
                     1_000

      await_graphql_runner_completion(session["id"], provider_pid)

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
      assert found_session["status"] == "completed"
      assert message["id"] in Enum.map(found_session["messages"], & &1["id"])
      assert message["id"] in Enum.map(query_result["data"]["chatMessages"], & &1["id"])
      refute Enum.any?(found_session["messages"], &(&1["role"] == "status"))
      refute Enum.any?(query_result["data"]["chatMessages"], &(&1["role"] == "status"))

      assistant_message =
        Enum.find(found_session["messages"], &(&1["role"] == "assistant"))

      assert assistant_message["content"] == "Assistant response from GraphQL runner"

      event_types = Enum.map(query_result["data"]["chatEvents"], & &1["eventType"])
      assert PublicEvents.event_type(:session_created) in event_types
      assert PublicEvents.event_type(:message_created) in event_types
      assert PublicEvents.event_type(:session_updated) in event_types
      refute "runner.tool_trace" in event_types

      message_event =
        Enum.find(
          query_result["data"]["chatEvents"],
          &(&1["eventType"] == PublicEvents.event_type(:message_created) and
              &1["payload"]["id"] == message["id"])
        )

      assert message_event["payload"]["content"] == "Plan the next step"
      refute Map.has_key?(message_event["payload"], "internal_payload")
      refute Map.has_key?(message_event["payload"], "secret")

      activity_event =
        Enum.find(
          query_result["data"]["chatEvents"],
          &(&1["eventType"] == "chat_runner_activity.invoking_model")
        )

      assert activity_event["payload"] == %{
               "chat_session_id" => session["id"],
               "phase" => "invoking_model",
               "status" => "running",
               "turn_message_id" => message["id"],
               "provider" => "fake",
               "model" => "graphql-test",
               "display" => %{"label" => "Invoking model"}
             }

      refute Map.has_key?(activity_event["payload"], "internal_payload")
      refute Map.has_key?(activity_event["payload"], "trace_id")

      second_send_result =
        graphql_result(conn, user, """
        mutation {
          sendChatMessage(
            projectId: "#{project.id}"
            chatSessionId: "#{session["id"]}"
            content: "What can you tell me about yourself?"
            contentFormat: "markdown"
            clientMessageId: "client-2"
          ) {
            id
            role
            content
            clientMessageId
          }
        }
        """)

      assert second_send_result["errors"] == nil
      second_message = second_send_result["data"]["sendChatMessage"]
      assert second_message["role"] == "user"
      assert second_message["content"] == "What can you tell me about yourself?"

      assert_receive {:fake_provider_called, second_provider_pid,
                      [
                        %{role: "system"},
                        %{role: "user", content: "Plan the next step"},
                        %{role: "assistant", content: "Assistant response from GraphQL runner"},
                        %{role: "user", content: "What can you tell me about yourself?"}
                      ]},
                     1_000

      await_graphql_runner_completion(session["id"], second_provider_pid)

      second_query_result =
        graphql_result(conn, user, """
        {
          chatSession(projectId: "#{project.id}", id: "#{session["id"]}") {
            id
            status
            messages { id content role clientMessageId }
          }
        }
        """)

      assert second_query_result["errors"] == nil
      second_found_session = second_query_result["data"]["chatSession"]
      assert second_found_session["status"] == "completed"

      messages = second_found_session["messages"]
      assert length(Enum.filter(messages, &(&1["role"] == "user"))) == 2
      assert length(Enum.filter(messages, &(&1["role"] == "assistant"))) == 2
      assert second_message["id"] in Enum.map(messages, & &1["id"])

      inference_completed_events =
        Repo.all(
          from event in ChatEvent,
            where:
              event.chat_session_id == ^session["id"] and
                event.event_type == "chat_inference.completed" and
                event.visibility == :internal
        )

      assert length(inference_completed_events) == 2
    end

    test "cancels a queued chat session", %{conn: conn, user: user, project: project} do
      create_result =
        graphql_result(conn, user, """
        mutation {
          createChatSession(projectId: "#{project.id}") { id }
        }
        """)

      session_id = create_result["data"]["createChatSession"]["id"]

      cancel_result =
        graphql_result(conn, user, """
        mutation {
          cancelChatSession(projectId: "#{project.id}", chatSessionId: "#{session_id}") {
            id
            status
            stopRequestedAt
            endedAt
          }
        }
        """)

      assert cancel_result["errors"] == nil
      cancelled = cancel_result["data"]["cancelChatSession"]
      assert cancelled["id"] == session_id
      assert cancelled["status"] == "cancelled"
      assert is_binary(cancelled["stopRequestedAt"])
      assert is_binary(cancelled["endedAt"])

      events_after_cancel =
        graphql_result(conn, user, """
        {
          chatEvents(projectId: "#{project.id}", chatSessionId: "#{session_id}") {
            eventType
            payload
          }
        }
        """)

      assert events_after_cancel["errors"] == nil

      events_after_cancel_types =
        Enum.map(events_after_cancel["data"]["chatEvents"], & &1["eventType"])

      assert PublicEvents.event_type(:session_created) in events_after_cancel_types
      assert PublicEvents.event_type(:session_updated) in events_after_cancel_types

      status_event =
        events_after_cancel["data"]["chatEvents"]
        |> Enum.filter(&(&1["eventType"] == PublicEvents.event_type(:session_updated)))
        |> List.last()

      assert status_event["payload"]["status"] == "cancelled"
      assert status_event["payload"]["id"] == session_id
    end

    test "treats duplicate runner starts as successful in-flight turns", %{
      conn: conn,
      user: user,
      project: project
    } do
      create_result =
        graphql_result(conn, user, """
        mutation {
          createChatSession(projectId: "#{project.id}") { id }
        }
        """)

      session_id = create_result["data"]["createChatSession"]["id"]

      first_send =
        graphql_result(conn, user, """
        mutation {
          sendChatMessage(
            projectId: "#{project.id}"
            chatSessionId: "#{session_id}"
            content: "first"
            clientMessageId: "client-duplicate-1"
          ) { id role content }
        }
        """)

      assert first_send["errors"] == nil

      assert_receive {:fake_provider_called, provider_pid,
                      [%{role: "system"}, %{role: "user", content: "first"}]},
                     2_000

      second_send =
        graphql_result(conn, user, """
        mutation {
          sendChatMessage(
            projectId: "#{project.id}"
            chatSessionId: "#{session_id}"
            content: "second"
            clientMessageId: "client-duplicate-2"
          ) { id role content }
        }
        """)

      assert second_send["errors"] == nil
      assert second_send["data"]["sendChatMessage"]["content"] == "second"
      assert [{runner_pid, _}] = Sacrum.ChatSessionRegistry.lookup(session_id)
      refute_receive {:fake_provider_called, _second_provider_pid, _messages}, 100

      await_task =
        Elixir.Task.async(fn -> Jido.AgentServer.await_completion(runner_pid, timeout: 2_000) end)

      send(provider_pid, :release_fake_provider)

      assert_receive {:fake_provider_called, second_provider_pid,
                      [
                        %{role: "system"},
                        %{role: "user", content: "first"},
                        %{role: "assistant", content: "Assistant response from GraphQL runner"},
                        %{role: "user", content: "second"}
                      ]},
                     2_000

      send(second_provider_pid, :release_fake_provider)

      assert {:ok, %{status: :completed}} = Elixir.Task.await(await_task, 2_500)
      assert_registry_empty(session_id)

      messages_result =
        graphql_result(conn, user, """
        {
          chatMessages(projectId: "#{project.id}", chatSessionId: "#{session_id}") {
            role
            content
          }
        }
        """)

      assert messages_result["errors"] == nil

      user_contents =
        messages_result["data"]["chatMessages"]
        |> Enum.filter(&(&1["role"] == "user"))
        |> Enum.map(& &1["content"])

      assert "first" in user_contents
      assert "second" in user_contents
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
      refute_receive {:fake_provider_called, _pid, _messages}

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

      delete_result =
        graphql_result(conn, other_user, """
        mutation {
          deleteChatSession(projectId: "#{project.id}", chatSessionId: "#{session_id}") {
            deletedSessionId
            success
          }
        }
        """)

      assert delete_result["data"]["deleteChatSession"] == nil
      assert [%{"message" => _}] = delete_result["errors"]
      assert {:ok, _still_present} = ChatSessions.get_session(user.id, project.id, session_id)
    end

    test "deletes an owned project chat session and removes it from history", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, kept_session} = ChatSessions.insert(user.id, project.id, %{})

      create_result =
        graphql_result(conn, user, """
        mutation {
          createChatSession(projectId: "#{project.id}") { id }
        }
        """)

      assert create_result["errors"] == nil
      session_id = create_result["data"]["createChatSession"]["id"]

      message_result =
        graphql_result(conn, user, """
        mutation {
          sendChatMessage(
            projectId: "#{project.id}"
            chatSessionId: "#{session_id}"
            content: "remove this transcript"
          ) { id }
        }
        """)

      assert message_result["errors"] == nil
      message_id = message_result["data"]["sendChatMessage"]["id"]

      assert_receive {:fake_provider_called, provider_pid,
                      [%{role: "system"}, %{role: "user", content: "remove this transcript"}]},
                     1_000

      await_graphql_runner_completion(session_id, provider_pid)

      public_event_ids =
        chat_event_ids_for_session(user.id, project.id, session_id)

      delete_result =
        graphql_result(conn, user, """
          mutation {
            deleteChatSession(projectId: "#{project.id}", chatSessionId: "#{session_id}") {
              deletedSessionId
              success
            }
          }
        """)

      assert delete_result["errors"] == nil

      assert delete_result["data"]["deleteChatSession"] == %{
               "deletedSessionId" => session_id,
               "success" => true
             }

      history_result =
        graphql_result(conn, user, """
        {
          chatSessions(projectId: "#{project.id}") { id }
          chatSession(projectId: "#{project.id}", id: "#{session_id}") { id }
        }
        """)

      assert Enum.map(history_result["data"]["chatSessions"], & &1["id"]) == [kept_session.id]
      assert history_result["data"]["chatSession"] == nil
      assert [%{"message" => _}] = history_result["errors"]

      refute Repo.get(ChatSession, session_id)
      refute Repo.get(ChatMessage, message_id)

      for event_id <- public_event_ids do
        refute Repo.get(ChatEvent, event_id)
      end
    end

    test "deleteChatSession rejects a session from another project and leaves it intact", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, other_project} =
        Accounts.Projects.insert(user.id, %{name: "Other Delete API Project"})

      {:ok, other_project_session} = ChatSessions.insert(user.id, other_project.id, %{})

      result =
        graphql_result(conn, user, """
        mutation {
          deleteChatSession(
            projectId: "#{project.id}"
            chatSessionId: "#{other_project_session.id}"
          ) {
            deletedSessionId
            success
          }
        }
        """)

      assert result["data"]["deleteChatSession"] == nil
      assert [%{"message" => _}] = result["errors"]

      assert {:ok, _still_present} =
               ChatSessions.get_session(user.id, other_project.id, other_project_session.id)
    end

    test "lists project chat sessions newest first with existing session fields", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, older_session} =
        ChatSessions.insert(user.id, project.id, %{
          session_kind: "planning",
          public_metadata: %{"label" => "older"}
        })

      {:ok, newer_session} =
        ChatSessions.insert(user.id, project.id, %{
          session_kind: "investigation",
          public_metadata: %{"label" => "newer"}
        })

      now = DateTime.utc_now()
      older_session = set_inserted_at!(older_session, DateTime.add(now, -1, :second))
      newer_session = set_inserted_at!(newer_session, now)

      {:ok, other_project} =
        Accounts.Projects.insert(user.id, %{name: "Other Chat API Project"})

      {:ok, other_project_session} = ChatSessions.insert(user.id, other_project.id, %{})

      other_user = create_user(%{email: "other-list@example.com", username: "other_list"})
      {:ok, other_user_project} = Accounts.Projects.insert(other_user.id, %{name: "Other User"})
      {:ok, other_user_session} = ChatSessions.insert(other_user.id, other_user_project.id, %{})

      result =
        graphql_result(conn, user, """
        {
          chatSessions(projectId: "#{project.id}") {
            id
            projectId
            status
            sessionKind
            publicMetadata
            insertedAt
            updatedAt
            messages { id }
            events { eventType }
          }
        }
        """)

      assert result["errors"] == nil
      sessions = result["data"]["chatSessions"]

      assert Enum.map(sessions, & &1["id"]) == [newer_session.id, older_session.id]
      refute other_project_session.id in Enum.map(sessions, & &1["id"])
      refute other_user_session.id in Enum.map(sessions, & &1["id"])

      assert [newer, older] = sessions
      assert newer["projectId"] == project.id
      assert newer["status"] == "queued"
      assert newer["sessionKind"] == "investigation"
      assert newer["publicMetadata"] == %{"label" => "newer"}
      assert is_binary(newer["insertedAt"])
      assert is_binary(newer["updatedAt"])
      assert newer["messages"] == []
      assert newer["events"] == []

      assert older["sessionKind"] == "planning"
      assert older["publicMetadata"] == %{"label" => "older"}
    end

    test "chatSession exposes only public redaction-safe artifacts linked to the session", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, session} = ChatSessions.insert(user.id, project.id, %{session_kind: "planning"})
      {:ok, other_session} = ChatSessions.insert(user.id, project.id, %{session_kind: "planning"})

      {:ok, %{artifact: public_artifact}} =
        Artifacts.create_and_link(
          user.id,
          project.id,
          chat_artifact_attrs(%{
            title: "Public plan",
            content: "User-safe planning output.",
            data: %{
              "source" => "chat",
              "chat_session_id" => session.id,
              "visibility_reason" => "reviewed"
            },
            storage_ref: "artifact://chat-session/public-plan"
          }),
          chat_session_artifact_link_attrs(session.id, %{
            relationship_kind: "produced_by",
            metadata: %{"provenance" => "chat_session"}
          })
        )

      {:ok, %{artifact: redacted_artifact}} =
        Artifacts.create_and_link(
          user.id,
          project.id,
          chat_artifact_attrs(%{
            title: "Redacted public summary",
            content: "Sensitive details removed.",
            redaction_state: "redacted"
          }),
          chat_session_artifact_link_attrs(session.id)
        )

      {:ok, %{artifact: internal_artifact}} =
        Artifacts.create_and_link(
          user.id,
          project.id,
          chat_artifact_attrs(%{
            title: "Internal trace",
            visibility: "internal",
            content: "operator-only tool trace"
          }),
          chat_session_artifact_link_attrs(session.id)
        )

      {:ok, %{artifact: blocked_artifact}} =
        Artifacts.create_and_link(
          user.id,
          project.id,
          chat_artifact_attrs(%{
            title: "Blocked redaction",
            redaction_state: "blocked",
            content: "not safe for public API"
          }),
          chat_session_artifact_link_attrs(session.id)
        )

      {:ok, %{artifact: other_session_artifact}} =
        Artifacts.create_and_link(
          user.id,
          project.id,
          chat_artifact_attrs(%{title: "Other session plan"}),
          chat_session_artifact_link_attrs(other_session.id)
        )

      result =
        graphql_result(conn, user, """
        {
          chatSession(projectId: "#{project.id}", id: "#{session.id}") {
            id
            artifacts {
              id
              artifactType
              artifactState
              title
              content
              redactionState
              insertedAt
              updatedAt
            }
          }
        }
        """)

      assert result["errors"] == nil
      assert found_session = result["data"]["chatSession"]
      assert found_session["id"] == session.id

      artifacts = found_session["artifacts"]
      artifact_ids = Enum.map(artifacts, & &1["id"])

      assert public_artifact.id in artifact_ids
      assert redacted_artifact.id in artifact_ids
      refute internal_artifact.id in artifact_ids
      refute blocked_artifact.id in artifact_ids
      refute other_session_artifact.id in artifact_ids

      assert public =
               Enum.find(artifacts, &(&1["id"] == public_artifact.id))

      assert public["artifactType"] == "plan"
      assert public["artifactState"] == "draft"
      assert public["title"] == "Public plan"
      assert public["content"] == "User-safe planning output."
      assert public["redactionState"] == "not_needed"
      assert is_binary(public["insertedAt"])
      assert is_binary(public["updatedAt"])

      refute Map.has_key?(public, "data")

      assert Enum.all?(artifacts, fn artifact ->
               MapSet.new(Map.keys(artifact)) ==
                 MapSet.new([
                   "artifactState",
                   "artifactType",
                   "content",
                   "id",
                   "insertedAt",
                   "redactionState",
                   "title",
                   "updatedAt"
                 ])
             end)

      assert redacted =
               Enum.find(artifacts, &(&1["id"] == redacted_artifact.id))

      assert redacted["redactionState"] == "redacted"
    end

    test "chatSessions respects and clamps limit through LiveChat", %{
      conn: conn,
      user: user,
      project: project
    } do
      for index <- 1..55 do
        {:ok, _session} =
          ChatSessions.insert(user.id, project.id, %{
            public_metadata: %{"index" => index}
          })
      end

      limited_result =
        graphql_result(conn, user, """
        {
          chatSessions(projectId: "#{project.id}", limit: 2) {
            id
          }
        }
        """)

      assert limited_result["errors"] == nil
      assert length(limited_result["data"]["chatSessions"]) == 2

      clamped_result =
        graphql_result(conn, user, """
        {
          chatSessions(projectId: "#{project.id}", limit: 999) {
            id
          }
        }
        """)

      assert clamped_result["errors"] == nil
      assert length(clamped_result["data"]["chatSessions"]) == 50
    end

    test "LiveChat list_sessions preserves Accounts scoping for unauthorized projects", %{
      user: user,
      project: project
    } do
      {:ok, session} = ChatSessions.insert(user.id, project.id, %{})

      other_user = create_user(%{email: "other-scope@example.com", username: "other_scope"})
      {:ok, other_project} = Accounts.Projects.insert(other_user.id, %{name: "Other Scope"})
      {:ok, other_session} = ChatSessions.insert(other_user.id, other_project.id, %{})

      assert Enum.map(LiveChat.list_sessions(user.id, project.id), & &1.id) == [session.id]
      assert LiveChat.list_sessions(user.id, other_project.id) == []

      assert Enum.map(LiveChat.list_sessions(other_user.id, other_project.id), & &1.id) == [
               other_session.id
             ]
    end
  end

  defp chat_event_ids_for_session(user_id, project_id, chat_session_id) do
    {:ok, events} = ChatEvents.list_public_for_session(user_id, project_id, chat_session_id)
    Enum.map(events, & &1.id)
  end

  defp await_graphql_runner_completion(session_id, provider_pid) do
    assert [{runner_pid, _}] = Sacrum.ChatSessionRegistry.lookup(session_id)

    await_task =
      Elixir.Task.async(fn -> Jido.AgentServer.await_completion(runner_pid, timeout: 1_000) end)

    send(provider_pid, :release_fake_provider)

    assert {:ok, %{status: :completed}} = Elixir.Task.await(await_task, 1_500)
    assert_registry_empty(session_id)
  end

  defp assert_registry_empty(session_id, attempts \\ 20)

  defp assert_registry_empty(session_id, attempts) when attempts > 0 do
    case Sacrum.ChatSessionRegistry.lookup(session_id) do
      [] ->
        :ok

      _registered ->
        Process.sleep(10)
        assert_registry_empty(session_id, attempts - 1)
    end
  end

  defp assert_registry_empty(session_id, 0) do
    assert [] = Sacrum.ChatSessionRegistry.lookup(session_id)
  end

  defp chat_artifact_attrs(attrs) do
    Map.merge(
      %{
        artifact_type: "plan",
        artifact_state: "draft",
        visibility: "public",
        redaction_state: "not_needed",
        title: "Chat plan",
        content: "Plan generated by the chat session.",
        data: %{}
      },
      attrs
    )
  end

  defp chat_session_artifact_link_attrs(session_id, attrs \\ %{}) do
    Map.merge(
      %{
        subject_type: "chat_session",
        subject_id: session_id,
        relationship_kind: "attached_to"
      },
      attrs
    )
  end
end
