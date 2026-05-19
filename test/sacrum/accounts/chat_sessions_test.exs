defmodule Sacrum.Accounts.ChatSessionsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.{ChatEvents, ChatMessages, ChatSessions}
  alias Sacrum.Accounts.Projects
  alias Sacrum.Chat.PublicEvents
  alias Sacrum.ChatSessions.Status, as: ChatSessionStatus
  alias Sacrum.Repo.Schemas.{ChatEvent, ChatMessage, ChatSession, StepExecution, TaskRun}
  alias Sacrum.Repo.Users

  defp create_user(prefix \\ "chat-session") do
    suffix = System.unique_integer([:positive])
    username_prefix = String.replace(prefix, "-", "_")

    {:ok, user} =
      Users.insert(%{
        email: "#{prefix}-#{suffix}@example.com",
        username: "#{username_prefix}_#{suffix}",
        password: "password123"
      })

    user
  end

  defp create_project(user, name \\ "Chat Project") do
    {:ok, project} = Projects.insert(user.id, %{name: name})
    project
  end

  defp setup_chat_project(_context) do
    user = create_user()
    project = create_project(user)

    %{user: user, project: project}
  end

  describe "status contract" do
    test "defines the V0 chat session lifecycle values" do
      assert ChatSessionStatus.values() == [
               :queued,
               :running,
               :waiting,
               :cancelling,
               :cancelled,
               :completed,
               :failed
             ]

      assert ChatSession.statuses() == ChatSessionStatus.values()
    end

    test "classifies active, terminal, successful, failed, and stoppable statuses" do
      for status <- [:queued, :running, :waiting, :cancelling] do
        assert ChatSessionStatus.active?(status)
        refute ChatSessionStatus.terminal?(status)
      end

      for status <- [:queued, :running, :waiting] do
        assert ChatSessionStatus.stoppable?(status)
      end

      refute ChatSessionStatus.stoppable?(:cancelling)

      for status <- [:cancelled, :completed, :failed] do
        assert ChatSessionStatus.terminal?(status)
        refute ChatSessionStatus.active?(status)
        refute ChatSessionStatus.stoppable?(status)
      end

      assert ChatSessionStatus.successful?(:completed)
      refute ChatSessionStatus.successful?(:cancelled)
      assert ChatSessionStatus.failed?(:failed)
      refute ChatSessionStatus.failed?(:completed)
    end
  end

  describe "ChatSession changesets" do
    test "validate required ownership fields and defaults" do
      changeset = ChatSession.create_changeset(%ChatSession{}, %{})

      assert %{project_id: ["can't be blank"], user_id: ["can't be blank"]} =
               errors_on(changeset)

      assert get_field(changeset, :status) == :queued
      assert get_field(changeset, :session_kind) == "planning"
      refute get_change(changeset, :started_at)
      refute get_change(changeset, :ended_at)
    end

    test "accepts lifecycle statuses and stamps transition timestamps" do
      chat_session = %ChatSession{
        project_id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate()
      }

      expected_timestamps = %{
        queued: [],
        running: [:started_at],
        waiting: [:started_at],
        cancelling: [:stop_requested_at],
        cancelled: [:ended_at],
        completed: [:ended_at],
        failed: [:ended_at]
      }

      for status <- ChatSessionStatus.values() do
        changeset = ChatSession.create_changeset(chat_session, %{status: status})

        assert changeset.valid?, "expected #{inspect(status)} to be valid"
        assert get_field(changeset, :status) == status

        for field <- Map.fetch!(expected_timestamps, status) do
          assert %DateTime{} = get_change(changeset, field)
        end
      end
    end

    test "rejects statuses outside the chat session contract" do
      chat_session = %ChatSession{
        project_id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate()
      }

      changeset = ChatSession.create_changeset(chat_session, %{status: :executing})

      assert %{status: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "insert/3" do
    setup [:setup_chat_project]

    test "creates a chat session scoped to user and project", %{user: user, project: project} do
      assert {:ok, %ChatSession{} = session} =
               ChatSessions.insert(user.id, project.id, %{
                 session_kind: "planning",
                 public_metadata: %{"source" => "command_center"}
               })

      assert session.user_id == user.id
      assert session.project_id == project.id
      assert session.status == :queued
      assert session.session_kind == "planning"
      assert session.public_metadata == %{"source" => "command_center"}
    end

    test "rejects creating a session in another user's project", %{project: project} do
      other_user = create_user("other-chat-session")

      assert {:error, :not_found} = ChatSessions.insert(other_user.id, project.id, %{})
    end
  end

  describe "artifact provenance helpers" do
    test "preserves scoped chat-session provenance arguments for artifact links" do
      session = %ChatSession{
        id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate(),
        project_id: Ecto.UUID.generate(),
        session_kind: "planning",
        status: :queued
      }

      source_message_id = Ecto.UUID.generate()
      session_id = session.id
      user_id = session.user_id
      project_id = session.project_id

      assert %{
               subject_type: "chat_session",
               subject_id: ^session_id,
               relationship_kind: "attached_to",
               metadata: %{
                 "provenance" => %{
                   user_id: ^user_id,
                   project_id: ^project_id,
                   chat_session_id: ^session_id,
                   source_message_id: ^source_message_id
                 }
               }
             } =
               ChatSessions.artifact_provenance_link_attrs(session,
                 relationship_kind: "attached_to",
                 source_message_id: source_message_id
               )
    end
  end

  describe "scoped reads and status transitions" do
    setup [:setup_chat_project]

    test "lists and fetches sessions only within the requested project", %{
      user: user,
      project: project
    } do
      other_project = create_project(user, "Other Chat Project")

      {:ok, session} = ChatSessions.insert(user.id, project.id, %{})
      {:ok, other_project_session} = ChatSessions.insert(user.id, other_project.id, %{})

      assert {:ok, found} = ChatSessions.get_session(user.id, project.id, session.id)
      assert found.id == session.id

      listed_ids = Enum.map(ChatSessions.list_sessions(user.id, project.id), & &1.id)

      assert session.id in listed_ids
      refute other_project_session.id in listed_ids

      assert {:error, :not_found} =
               ChatSessions.get_session(user.id, other_project.id, session.id)
    end

    test "updates session status without touching TaskRun or StepExecution state", %{
      user: user,
      project: project
    } do
      {:ok, session} = ChatSessions.insert(user.id, project.id, %{})

      assert Repo.aggregate(TaskRun, :count) == 0
      assert Repo.aggregate(StepExecution, :count) == 0

      assert {:ok, running} =
               ChatSessions.transition_status(user.id, project.id, session.id, :running)

      assert running.status == :running
      assert %DateTime{} = running.started_at
      assert is_nil(running.ended_at)

      assert {:ok, completed} =
               ChatSessions.transition_status(user.id, project.id, session.id, :completed)

      assert completed.status == :completed
      assert completed.started_at == running.started_at
      assert %DateTime{} = completed.ended_at
      assert Repo.aggregate(TaskRun, :count) == 0
      assert Repo.aggregate(StepExecution, :count) == 0
    end

    test "hard deletes a scoped session and cascades related messages and events", %{
      user: user,
      project: project
    } do
      other_project = create_project(user, "Other Delete Scope")

      {:ok, session} = ChatSessions.insert(user.id, project.id, %{})
      {:ok, other_session} = ChatSessions.insert(user.id, other_project.id, %{})

      {:ok, message} =
        ChatMessages.append(user.id, project.id, session.id, %{
          role: :user,
          content: "delete me",
          content_format: :plain
        })

      {:ok, event} =
        ChatEvents.append(
          user.id,
          project.id,
          session.id,
          PublicEvents.message_created_attrs(message)
        )

      assert {:error, :not_found} =
               ChatSessions.delete_session(user.id, other_project.id, session.id)

      assert {:ok, _still_present} = ChatSessions.get_session(user.id, project.id, session.id)

      assert {:ok, deleted} = ChatSessions.delete_session(user.id, project.id, session.id)
      assert deleted.id == session.id

      assert {:error, :not_found} = ChatSessions.get_session(user.id, project.id, session.id)
      assert Enum.map(ChatSessions.list_sessions(user.id, project.id), & &1.id) == []

      assert Enum.map(ChatSessions.list_sessions(user.id, other_project.id), & &1.id) == [
               other_session.id
             ]

      refute Repo.get(ChatSession, session.id)
      refute Repo.get(ChatMessage, message.id)
      refute Repo.get(ChatEvent, event.id)
    end
  end
end
