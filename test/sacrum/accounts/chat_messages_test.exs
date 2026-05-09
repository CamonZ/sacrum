defmodule Sacrum.Accounts.ChatMessagesTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.ChatMessages
  alias Sacrum.Accounts.ChatSessions
  alias Sacrum.Accounts.Projects
  alias Sacrum.Repo.Schemas.ChatMessage
  alias Sacrum.Repo.Users

  defp create_user(prefix \\ "chat-message") do
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

  defp create_project(user, name \\ "Message Project") do
    {:ok, project} = Projects.insert(user.id, %{name: name})
    project
  end

  defp create_session(user, project) do
    {:ok, session} = ChatSessions.insert(user.id, project.id, %{})
    session
  end

  defp setup_session(_context) do
    user = create_user()
    project = create_project(user)
    session = create_session(user, project)

    %{user: user, project: project, session: session}
  end

  describe "ChatMessage changesets" do
    test "validate required public transcript fields" do
      changeset =
        ChatMessage.create_changeset(
          %ChatMessage{
            user_id: Ecto.UUID.generate(),
            project_id: Ecto.UUID.generate(),
            chat_session_id: Ecto.UUID.generate()
          },
          %{}
        )

      assert %{role: ["can't be blank"], content: ["can't be blank"]} = errors_on(changeset)
      assert get_field(changeset, :content_format) == :plain
    end

    test "rejects invalid role and metadata values" do
      changeset =
        ChatMessage.create_changeset(
          %ChatMessage{
            user_id: Ecto.UUID.generate(),
            project_id: Ecto.UUID.generate(),
            chat_session_id: Ecto.UUID.generate()
          },
          %{role: :developer, content: "hidden", metadata: "not a map"}
        )

      assert %{role: ["is invalid"], metadata: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "append/4 and list_for_session/3" do
    setup [:setup_session]

    test "appends public chat messages scoped to the session", %{
      user: user,
      project: project,
      session: session
    } do
      assert {:ok, user_message} =
               ChatMessages.append(user.id, project.id, session.id, %{
                 role: :user,
                 content: "Draft a plan",
                 client_message_id: "client-1",
                 metadata: %{"source" => "ui"}
               })

      assert {:ok, assistant_message} =
               ChatMessages.append(user.id, project.id, session.id, %{
                 role: :assistant,
                 content: "Here is the plan.",
                 content_format: :markdown
               })

      assert user_message.user_id == user.id
      assert user_message.project_id == project.id
      assert user_message.chat_session_id == session.id
      assert user_message.metadata == %{"source" => "ui"}

      assert {:ok, messages} = ChatMessages.list_for_session(user.id, project.id, session.id)

      assert Enum.map(messages, & &1.id) == [user_message.id, assistant_message.id]
      assert Enum.map(messages, & &1.role) == [:user, :assistant]
      assert Enum.map(messages, & &1.content) == ["Draft a plan", "Here is the plan."]
    end

    test "rejects appends across users or projects", %{
      user: user,
      project: project,
      session: session
    } do
      other_user = create_user("other-chat-message")
      other_project = create_project(user, "Other Message Project")

      attrs = %{role: :user, content: "not allowed"}

      assert {:error, :not_found} =
               ChatMessages.append(other_user.id, project.id, session.id, attrs)

      assert {:error, :not_found} =
               ChatMessages.append(user.id, other_project.id, session.id, attrs)

      assert {:ok, []} = ChatMessages.list_for_session(user.id, project.id, session.id)
    end
  end
end
