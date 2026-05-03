defmodule Sacrum.Accounts.WorkflowsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.Workflows
  alias Sacrum.Accounts.Projects
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Schemas.Workflow

  @valid_user_attrs %{
    email: "test@example.com",
    username: "testuser",
    password: "password123"
  }

  defp create_user(attrs \\ @valid_user_attrs) do
    {:ok, user} = Users.insert(attrs)
    user
  end

  defp create_project(user) do
    {:ok, project} = Projects.insert(user.id, %{name: "Test Project"})
    project
  end

  describe "insert/3" do
    test "creates workflow scoped to user_id and project_id" do
      user = create_user()
      project = create_project(user)

      assert {:ok, %Workflow{} = workflow} =
               Workflows.insert(user.id, project.id, %{name: "My Workflow"})

      assert workflow.user_id == user.id
      assert workflow.project_id == project.id
      assert workflow.name == "My Workflow"
    end

    test "accepts project struct and extracts ids" do
      user = create_user()
      project = create_project(user)

      assert {:ok, %Workflow{} = workflow} =
               Workflows.insert(project, %{name: "My Workflow"})

      assert workflow.user_id == user.id
      assert workflow.project_id == project.id
    end
  end

  describe "get_by/2" do
    test "returns workflow only if scoped to user" do
      user1 = create_user()
      project1 = create_project(user1)

      user2 =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      project2 = create_project(user2)

      {:ok, workflow} = Workflows.insert(user1.id, project1.id, %{name: "User1 Workflow"})
      {:ok, _} = Workflows.insert(user2.id, project2.id, %{name: "User2 Workflow"})

      # User1 can access their workflow
      assert {:ok, found} = Workflows.get_by(user1.id, conditions: [id: workflow.id])
      assert found.id == workflow.id
      assert found.user_id == user1.id

      # User2 cannot access user1's workflow
      assert {:error, :not_found} = Workflows.get_by(user2.id, conditions: [id: workflow.id])
    end
  end

  describe "list_by/2" do
    test "returns only workflows scoped to user" do
      user1 = create_user()
      project1 = create_project(user1)

      user2 =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      project2 = create_project(user2)

      {:ok, _} = Workflows.insert(user1.id, project1.id, %{name: "User1 Workflow"})
      {:ok, _} = Workflows.insert(user2.id, project2.id, %{name: "User2 Workflow"})

      workflows = Workflows.list_by(user1.id)
      assert length(workflows) == 2
      assert Enum.all?(workflows, &(&1.user_id == user1.id))
    end

    test "filters by project_id" do
      user = create_user()
      project1 = create_project(user)
      {:ok, project2} = Projects.insert(user.id, %{name: "Project 2"})

      {:ok, _} = Workflows.insert(user.id, project1.id, %{name: "Workflow 1"})
      {:ok, _} = Workflows.insert(user.id, project2.id, %{name: "Workflow 2"})

      workflows = Workflows.list_by(user.id, conditions: [project_id: project1.id])
      assert length(workflows) == 2
      assert Enum.all?(workflows, &(&1.project_id == project1.id))
      assert Enum.any?(workflows, &(&1.name == "Backlog"))
      assert Enum.any?(workflows, &(&1.name == "Workflow 1"))
    end
  end
end
