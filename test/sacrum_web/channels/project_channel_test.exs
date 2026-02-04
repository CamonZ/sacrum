defmodule SacrumWeb.ProjectChannelTest do
  use Sacrum.DataCase, async: true

  import Phoenix.ChannelTest

  alias SacrumWeb.UserSocket
  alias Sacrum.Auth
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Projects

  @endpoint SacrumWeb.Endpoint

  @valid_user_attrs %{
    email: "channel@example.com",
    username: "channeluser",
    password: "password123"
  }

  @project_attrs %{name: "Test Project"}

  defp setup_socket do
    {:ok, user} = Users.insert(@valid_user_attrs)
    {:ok, token, _api_token} = Auth.create_api_token(user, %{name: "test token"})
    {:ok, project} = Projects.insert(user, @project_attrs)

    {:ok, socket} = connect(UserSocket, %{"token" => token})
    {user, project, socket}
  end

  describe "join/3" do
    test "can join project channel for owned project" do
      {_user, project, socket} = setup_socket()

      assert {:ok, _reply, socket} = subscribe_and_join(socket, "project:#{project.id}")
      assert socket.assigns.project.id == project.id
    end

    test "cannot join channel for another user's project" do
      {_user, _project, socket} = setup_socket()

      # Create a project owned by a different user
      {:ok, other_user} =
        Users.insert(%{email: "other@example.com", username: "other", password: "password123"})

      {:ok, other_project} = Projects.insert(other_user, %{name: "Other Project"})

      assert {:error, %{reason: "not found"}} =
               subscribe_and_join(socket, "project:#{other_project.id}")
    end

    test "cannot join channel for nonexistent project" do
      {_user, _project, socket} = setup_socket()

      assert {:error, %{reason: "not found"}} =
               subscribe_and_join(socket, "project:#{Ecto.UUID.generate()}")
    end
  end

  describe "broadcast helpers" do
    test "broadcast_task_created sends task_created event" do
      {_user, project, socket} = setup_socket()
      {:ok, _reply, _socket} = subscribe_and_join(socket, "project:#{project.id}")

      task = build_task(project)

      SacrumWeb.ProjectChannel.broadcast_task_created(project.id, task)

      assert_broadcast "task_created", payload
      assert payload.id == task.id
      assert payload.title == task.title
    end

    test "broadcast_task_updated sends task_updated event" do
      {_user, project, socket} = setup_socket()
      {:ok, _reply, _socket} = subscribe_and_join(socket, "project:#{project.id}")

      task = build_task(project)

      SacrumWeb.ProjectChannel.broadcast_task_updated(project.id, task)

      assert_broadcast "task_updated", payload
      assert payload.id == task.id
    end

    test "broadcast_task_deleted sends task_deleted event with id only" do
      {_user, project, socket} = setup_socket()
      {:ok, _reply, _socket} = subscribe_and_join(socket, "project:#{project.id}")

      task = build_task(project)

      SacrumWeb.ProjectChannel.broadcast_task_deleted(project.id, task)

      assert_broadcast "task_deleted", %{id: id}
      assert id == task.id
    end

    test "broadcast_workflow_changed sends workflow_changed event" do
      {_user, project, socket} = setup_socket()
      {:ok, _reply, _socket} = subscribe_and_join(socket, "project:#{project.id}")

      task = build_task(project)

      SacrumWeb.ProjectChannel.broadcast_workflow_changed(project.id, task)

      assert_broadcast "workflow_changed", payload
      assert payload.id == task.id
      assert payload.workflow_id == task.workflow_id
    end
  end

  defp build_task(project) do
    now = DateTime.utc_now()

    %{
      id: Ecto.UUID.generate(),
      short_id: "xabc123",
      title: "Test Task",
      description: "A task",
      level: "task",
      priority: "medium",
      tags: ["test"],
      needs_human_review: false,
      started_at: now,
      completed_at: nil,
      project_id: project.id,
      workflow_id: nil,
      current_step_id: nil,
      inserted_at: now,
      updated_at: now
    }
  end
end
