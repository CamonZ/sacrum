defmodule Sacrum.Accounts.ProjectsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.Projects
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Schemas.Project

  @valid_user_attrs %{
    email: "test@example.com",
    username: "testuser",
    password: "password123"
  }

  defp create_user(attrs \\ @valid_user_attrs) do
    {:ok, user} = Users.insert(attrs)
    user
  end

  describe "insert/2" do
    test "creates project scoped to the given user_id" do
      user = create_user()

      assert {:ok, %Project{} = project} =
               Projects.insert(user.id, %{name: "My Project"})

      assert project.user_id == user.id
      assert project.name == "My Project"
    end

    test "different users get their own projects" do
      user1 = create_user()

      user2 =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      {:ok, project1} = Projects.insert(user1.id, %{name: "Project 1"})
      {:ok, project2} = Projects.insert(user2.id, %{name: "Project 2"})

      assert project1.user_id == user1.id
      assert project2.user_id == user2.id
      assert project1.user_id != project2.user_id
    end
  end

  describe "get_by/2" do
    test "returns project only if scoped to user" do
      user1 = create_user()

      user2 =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      {:ok, project} = Projects.insert(user1.id, %{name: "My Project"})

      # User1 can access their project
      assert {:ok, found} = Projects.get_by(user1.id, conditions: [id: project.id])
      assert found.id == project.id

      # User2 cannot access user1's project
      assert {:error, :not_found} = Projects.get_by(user2.id, conditions: [id: project.id])
    end
  end

  describe "list_by/2" do
    test "returns only projects scoped to user" do
      user1 = create_user()

      user2 =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      {:ok, _} = Projects.insert(user1.id, %{name: "User1 Project"})
      {:ok, _} = Projects.insert(user2.id, %{name: "User2 Project"})

      projects = Projects.list_by(user1.id)
      assert length(projects) == 1
      assert hd(projects).user_id == user1.id
    end
  end
end
