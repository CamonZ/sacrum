defmodule Sacrum.Accounts.WorkflowsShortIdTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.Workflows
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Projects

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
    {:ok, project} = Projects.insert(user, %{name: "Test Project"})
    project
  end

  describe "resolve_short_id/3" do
    test "resolves UUID prefix to workflow within project" do
      user = create_user()
      project = create_project(user)
      {:ok, workflow} = Workflows.insert(user.id, project.id, %{name: "Resolvable"})

      prefix = String.slice(workflow.id, 0, 8)
      assert {:ok, found} = Workflows.resolve_short_id(user.id, project.id, prefix)
      assert found.id == workflow.id
    end

    test "scopes to project" do
      user = create_user()
      p1 = create_project(user)
      {:ok, p2} = Projects.insert(user, %{name: "Other Project"})
      {:ok, workflow} = Workflows.insert(user.id, p1.id, %{name: "P1 Workflow"})

      prefix = String.slice(workflow.id, 0, 8)
      assert {:ok, _} = Workflows.resolve_short_id(user.id, p1.id, prefix)
      assert {:error, :not_found} = Workflows.resolve_short_id(user.id, p2.id, prefix)
    end

    test "scopes to user" do
      user1 = create_user()
      project1 = create_project(user1)

      user2 =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      {:ok, workflow} = Workflows.insert(user1.id, project1.id, %{name: "User1 Workflow"})

      prefix = String.slice(workflow.id, 0, 8)
      assert {:ok, _} = Workflows.resolve_short_id(user1.id, project1.id, prefix)
      assert {:error, :not_found} = Workflows.resolve_short_id(user2.id, project1.id, prefix)
    end

    test "returns error for invalid prefix" do
      user = create_user()
      project = create_project(user)

      assert {:error, :invalid_prefix} =
               Workflows.resolve_short_id(user.id, project.id, "zzzzzzzz")
    end

    test "returns error for unknown prefix within scope" do
      user = create_user()
      project = create_project(user)

      assert {:error, :not_found} = Workflows.resolve_short_id(user.id, project.id, "00000000")
    end
  end
end
