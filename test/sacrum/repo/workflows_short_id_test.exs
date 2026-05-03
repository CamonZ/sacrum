defmodule Sacrum.Repo.WorkflowsShortIdTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Workflows

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

  defp create_workflow(user_id, project_id, attrs \\ %{}) do
    default_attrs = Map.merge(%{name: "Test Workflow"}, attrs)
    Workflows.insert(project_id, user_id, default_attrs)
  end

  describe "find_by_uuid_prefix/3" do
    test "finds workflow by the first 8 characters of its UUID" do
      user = create_user()
      project = create_project(user)
      {:ok, workflow} = create_workflow(user.id, project.id)

      prefix = String.slice(workflow.id, 0, 8)
      assert {:ok, found} = Workflows.find_by_uuid_prefix(prefix, project.id, user.id)
      assert found.id == workflow.id
    end

    test "finds workflow by shorter prefixes" do
      user = create_user()
      project = create_project(user)
      {:ok, workflow} = create_workflow(user.id, project.id)

      prefix = String.slice(workflow.id, 0, 4)
      assert {:ok, found} = Workflows.find_by_uuid_prefix(prefix, project.id, user.id)
      assert found.id == workflow.id
    end

    test "is case-insensitive" do
      user = create_user()
      project = create_project(user)
      {:ok, workflow} = create_workflow(user.id, project.id)

      prefix = workflow.id |> String.slice(0, 8) |> String.upcase()
      assert {:ok, found} = Workflows.find_by_uuid_prefix(prefix, project.id, user.id)
      assert found.id == workflow.id
    end

    test "returns :not_found for non-matching prefix" do
      user = create_user()
      project = create_project(user)
      {:ok, _workflow} = create_workflow(user.id, project.id)

      assert {:error, :not_found} = Workflows.find_by_uuid_prefix("00000000", project.id, user.id)
    end

    test "scopes to project" do
      user = create_user()
      p1 = create_project(user)
      {:ok, p2} = Projects.insert(user, %{name: "Other Project"})
      {:ok, workflow} = create_workflow(user.id, p1.id)

      prefix = String.slice(workflow.id, 0, 8)

      assert {:ok, _} = Workflows.find_by_uuid_prefix(prefix, p1.id, user.id)
      assert {:error, :not_found} = Workflows.find_by_uuid_prefix(prefix, p2.id, user.id)
    end

    test "scopes to user" do
      user1 = create_user()

      user2 =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      project = create_project(user1)
      {:ok, workflow} = create_workflow(user1.id, project.id)

      prefix = String.slice(workflow.id, 0, 8)

      assert {:ok, _} = Workflows.find_by_uuid_prefix(prefix, project.id, user1.id)
      assert {:error, :not_found} = Workflows.find_by_uuid_prefix(prefix, project.id, user2.id)
    end

    test "returns :invalid_prefix for non-hex input" do
      user = create_user()
      project = create_project(user)

      assert {:error, :invalid_prefix} =
               Workflows.find_by_uuid_prefix("ghijklmn", project.id, user.id)
    end

    test "returns :invalid_prefix for prefix longer than 8 characters" do
      user = create_user()
      project = create_project(user)

      assert {:error, :invalid_prefix} =
               Workflows.find_by_uuid_prefix("abcdef012", project.id, user.id)
    end

    test "returns :invalid_prefix for empty string" do
      user = create_user()
      project = create_project(user)

      assert {:error, :invalid_prefix} = Workflows.find_by_uuid_prefix("", project.id, user.id)
    end

    test "returns {:ambiguous, candidates} when multiple workflows share prefix" do
      user = create_user()
      project = create_project(user)

      workflows =
        Enum.map(1..32, fn i ->
          {:ok, w} = create_workflow(user.id, project.id, %{name: "Workflow #{i}"})
          w
        end)

      {prefix, shared} =
        workflows
        |> Enum.group_by(&String.slice(&1.id, 0, 1))
        |> Enum.find(fn {_p, ws} -> length(ws) >= 2 end)

      assert {:error, {:ambiguous, candidates}} =
               Workflows.find_by_uuid_prefix(prefix, project.id, user.id)

      assert length(candidates) >= 2
      shared_ids = Enum.map(shared, & &1.id)
      assert Enum.all?(candidates, &(&1 in shared_ids))
    end
  end
end
