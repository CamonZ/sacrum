defmodule Sacrum.Repo.WorkflowStepsShortIdTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Workflows
  alias Sacrum.Repo.WorkflowSteps

  defp create_user(suffix \\ "1") do
    {:ok, user} =
      Users.insert(%{
        email: "test#{suffix}@example.com",
        username: "testuser#{suffix}",
        password: "password123"
      })

    user
  end

  defp create_project(user, name \\ "Test Project") do
    {:ok, project} = Projects.insert(user, %{name: name})
    project
  end

  defp create_workflow(user_id, project_id, attrs \\ %{}) do
    Workflows.insert(project_id, user_id, Map.merge(%{name: "Test Workflow"}, attrs))
  end

  defp create_step(workflow_id, project_id, user_id, attrs \\ %{}) do
    WorkflowSteps.insert(
      workflow_id,
      project_id,
      user_id,
      Map.merge(%{name: "Test Step", step_order: 1}, attrs)
    )
  end

  describe "find_by_uuid_prefix/4" do
    test "finds step by the first 8 characters of its UUID" do
      user = create_user()
      project = create_project(user)
      {:ok, workflow} = create_workflow(user.id, project.id)
      {:ok, step} = create_step(workflow.id, project.id, user.id)

      prefix = String.slice(step.id, 0, 8)

      assert {:ok, found} =
               WorkflowSteps.find_by_uuid_prefix(prefix, project.id, workflow.id, user.id)

      assert found.id == step.id
    end

    test "finds step by shorter prefixes" do
      user = create_user()
      project = create_project(user)
      {:ok, workflow} = create_workflow(user.id, project.id)
      {:ok, step} = create_step(workflow.id, project.id, user.id)

      prefix = String.slice(step.id, 0, 4)

      assert {:ok, found} =
               WorkflowSteps.find_by_uuid_prefix(prefix, project.id, workflow.id, user.id)

      assert found.id == step.id
    end

    test "is case-insensitive" do
      user = create_user()
      project = create_project(user)
      {:ok, workflow} = create_workflow(user.id, project.id)
      {:ok, step} = create_step(workflow.id, project.id, user.id)

      prefix = step.id |> String.slice(0, 8) |> String.upcase()

      assert {:ok, found} =
               WorkflowSteps.find_by_uuid_prefix(prefix, project.id, workflow.id, user.id)

      assert found.id == step.id
    end

    test "returns :not_found for non-matching prefix" do
      user = create_user()
      project = create_project(user)
      {:ok, workflow} = create_workflow(user.id, project.id)
      {:ok, _step} = create_step(workflow.id, project.id, user.id)

      assert {:error, :not_found} =
               WorkflowSteps.find_by_uuid_prefix("00000000", project.id, workflow.id, user.id)
    end

    test "scopes to workflow" do
      user = create_user()
      project = create_project(user)
      {:ok, w1} = create_workflow(user.id, project.id, %{name: "Workflow 1"})
      {:ok, w2} = create_workflow(user.id, project.id, %{name: "Workflow 2"})
      {:ok, step} = create_step(w1.id, project.id, user.id)

      prefix = String.slice(step.id, 0, 8)

      assert {:ok, _} =
               WorkflowSteps.find_by_uuid_prefix(prefix, project.id, w1.id, user.id)

      assert {:error, :not_found} =
               WorkflowSteps.find_by_uuid_prefix(prefix, project.id, w2.id, user.id)
    end

    test "scopes to project" do
      user = create_user()
      p1 = create_project(user, "Project 1")
      p2 = create_project(user, "Project 2")
      {:ok, w1} = create_workflow(user.id, p1.id)
      {:ok, step} = create_step(w1.id, p1.id, user.id)

      prefix = String.slice(step.id, 0, 8)

      assert {:ok, _} = WorkflowSteps.find_by_uuid_prefix(prefix, p1.id, w1.id, user.id)

      assert {:error, :not_found} =
               WorkflowSteps.find_by_uuid_prefix(prefix, p2.id, w1.id, user.id)
    end

    test "scopes to user" do
      user1 = create_user("1")
      user2 = create_user("2")
      project = create_project(user1)
      {:ok, workflow} = create_workflow(user1.id, project.id)
      {:ok, step} = create_step(workflow.id, project.id, user1.id)

      prefix = String.slice(step.id, 0, 8)

      assert {:ok, _} =
               WorkflowSteps.find_by_uuid_prefix(prefix, project.id, workflow.id, user1.id)

      assert {:error, :not_found} =
               WorkflowSteps.find_by_uuid_prefix(prefix, project.id, workflow.id, user2.id)
    end

    test "returns :invalid_prefix for non-hex input" do
      user = create_user()
      project = create_project(user)
      {:ok, workflow} = create_workflow(user.id, project.id)

      assert {:error, :invalid_prefix} =
               WorkflowSteps.find_by_uuid_prefix("ghijklmn", project.id, workflow.id, user.id)
    end

    test "returns :invalid_prefix for prefix longer than 8 characters" do
      user = create_user()
      project = create_project(user)
      {:ok, workflow} = create_workflow(user.id, project.id)

      assert {:error, :invalid_prefix} =
               WorkflowSteps.find_by_uuid_prefix("abcdef012", project.id, workflow.id, user.id)
    end

    test "returns :invalid_prefix for empty string" do
      user = create_user()
      project = create_project(user)
      {:ok, workflow} = create_workflow(user.id, project.id)

      assert {:error, :invalid_prefix} =
               WorkflowSteps.find_by_uuid_prefix("", project.id, workflow.id, user.id)
    end

    test "returns {:ambiguous, candidates} when multiple steps share prefix" do
      user = create_user()
      project = create_project(user)
      {:ok, workflow} = create_workflow(user.id, project.id)

      steps =
        Enum.map(1..32, fn i ->
          {:ok, s} =
            create_step(workflow.id, project.id, user.id, %{name: "Step #{i}", step_order: i})

          s
        end)

      {prefix, shared} =
        steps
        |> Enum.group_by(&String.slice(&1.id, 0, 1))
        |> Enum.find(fn {_p, ss} -> length(ss) >= 2 end)

      assert {:error, {:ambiguous, candidates}} =
               WorkflowSteps.find_by_uuid_prefix(prefix, project.id, workflow.id, user.id)

      assert length(candidates) >= 2
      shared_ids = Enum.map(shared, & &1.id)
      assert Enum.all?(candidates, &(&1 in shared_ids))
    end
  end
end
