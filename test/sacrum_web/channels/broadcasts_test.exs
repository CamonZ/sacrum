defmodule SacrumWeb.BroadcastsTest do
  use Sacrum.DataCase, async: true

  import Phoenix.ChannelTest

  alias SacrumWeb.UserSocket
  alias Sacrum.Auth
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Tasks

  @endpoint SacrumWeb.Endpoint

  @valid_user_attrs %{
    email: "broadcast@example.com",
    username: "broadcastuser",
    password: "password123"
  }

  defp setup_channel do
    {:ok, user} = Users.insert(@valid_user_attrs)
    {:ok, token, _api_token} = Auth.create_api_token(user, %{name: "test token"})
    {:ok, project} = Projects.insert(user, %{name: "Broadcast Project"})

    {:ok, socket} = connect(UserSocket, %{"token" => token})
    {:ok, _reply, _socket} = subscribe_and_join(socket, "project:#{project.id}")

    {user, project}
  end

  describe "task broadcasts from context" do
    test "creating a task broadcasts task_created" do
      {_user, project} = setup_channel()

      {:ok, task} = Tasks.insert(project, %{title: "New Task"})

      assert_broadcast "task_created", payload
      assert payload.id == task.id
      assert payload.title == "New Task"
      assert payload.project_id == project.id
    end

    test "updating a task broadcasts task_updated" do
      {_user, project} = setup_channel()

      {:ok, task} = Tasks.insert(project, %{title: "Original"})
      assert_broadcast "task_created", _

      {:ok, updated} = Tasks.update(task, %{title: "Updated"})

      assert_broadcast "task_updated", payload
      assert payload.id == updated.id
      assert payload.title == "Updated"
    end

    test "deleting a task broadcasts task_deleted" do
      {_user, project} = setup_channel()

      {:ok, task} = Tasks.insert(project, %{title: "To Delete"})
      assert_broadcast "task_created", _

      {:ok, _} = Tasks.delete(task)

      assert_broadcast "task_deleted", %{id: id}
      assert id == task.id
    end
  end
end
