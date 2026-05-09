defmodule Sacrum.Accounts.ChatEventsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.ChatEvents
  alias Sacrum.Accounts.ChatSessions
  alias Sacrum.Accounts.Projects
  alias Sacrum.Repo.ChatEvents, as: ChatEventsRepo
  alias Sacrum.Repo.Schemas.ChatEvent
  alias Sacrum.Repo.Users

  defp create_user(prefix \\ "chat-event") do
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

  defp create_project(user, name \\ "Event Project") do
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

  describe "ChatEvent changesets" do
    test "validate required event fields and visibility values" do
      base_event = %ChatEvent{
        user_id: Ecto.UUID.generate(),
        project_id: Ecto.UUID.generate(),
        chat_session_id: Ecto.UUID.generate()
      }

      assert ChatEvent.visibilities() == [:public, :internal]

      missing = ChatEvent.create_changeset(base_event, %{})
      assert %{event_type: ["can't be blank"]} = errors_on(missing)
      assert get_field(missing, :visibility) == :public

      invalid =
        ChatEvent.create_changeset(base_event, %{
          event_type: "planner.debug",
          visibility: :operator,
          public_payload: "not a map"
        })

      assert %{visibility: ["is invalid"], public_payload: ["is invalid"]} =
               errors_on(invalid)
    end
  end

  describe "append/4 and list_public_for_session/3" do
    setup [:setup_session]

    test "stores public and internal events but public helpers omit internal payloads", %{
      user: user,
      project: project,
      session: session
    } do
      assert {:ok, public_event} =
               ChatEvents.append(user.id, project.id, session.id, %{
                 event_type: "planner.started",
                 visibility: :public,
                 public_payload: %{"label" => "Planning started"},
                 internal_payload: %{"trace_id" => "hidden-public-trace"}
               })

      assert {:ok, internal_event} =
               ChatEvents.append(user.id, project.id, session.id, %{
                 event_type: "planner.trace",
                 visibility: :internal,
                 internal_payload: %{"command" => "secret shell output"}
               })

      assert {:ok, stored_internal} = ChatEventsRepo.get(internal_event.id)
      assert stored_internal.internal_payload == %{"command" => "secret shell output"}

      assert {:ok, events} = ChatEvents.list_public_for_session(user.id, project.id, session.id)

      assert Enum.map(events, & &1.id) == [public_event.id]
      assert [projected_public] = events
      assert projected_public.public_payload == %{"label" => "Planning started"}
      refute Map.has_key?(projected_public, :internal_payload)
    end

    test "rejects appends across users or projects", %{
      user: user,
      project: project,
      session: session
    } do
      other_user = create_user("other-chat-event")
      other_project = create_project(user, "Other Event Project")

      attrs = %{event_type: "planner.started", visibility: :public}

      assert {:error, :not_found} =
               ChatEvents.append(other_user.id, project.id, session.id, attrs)

      assert {:error, :not_found} =
               ChatEvents.append(user.id, other_project.id, session.id, attrs)

      assert {:ok, []} = ChatEvents.list_public_for_session(user.id, project.id, session.id)
    end
  end
end
