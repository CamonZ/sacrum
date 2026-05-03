defmodule Sacrum.Accounts.WorkflowStepsShortIdTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.Workflows
  alias Sacrum.Accounts.WorkflowSteps
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Projects

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

  defp insert_step(user, project, workflow, name) do
    {:ok, step} =
      WorkflowSteps.insert(user.id, %{
        workflow_id: workflow.id,
        project_id: project.id,
        name: name,
        step_order: 1
      })

    step
  end

  describe "resolve_short_id/4" do
    test "resolves UUID prefix to step within (user, project, workflow)" do
      user = create_user()
      project = create_project(user)
      {:ok, workflow} = Workflows.insert(user.id, project.id, %{name: "Test Workflow"})
      step = insert_step(user, project, workflow, "Resolvable")

      prefix = String.slice(step.id, 0, 8)

      assert {:ok, found} =
               WorkflowSteps.resolve_short_id(user.id, project.id, workflow.id, prefix)

      assert found.id == step.id
    end

    test "scopes to workflow" do
      user = create_user()
      project = create_project(user)
      {:ok, w1} = Workflows.insert(user.id, project.id, %{name: "Workflow 1"})
      {:ok, w2} = Workflows.insert(user.id, project.id, %{name: "Workflow 2"})
      step = insert_step(user, project, w1, "W1 Step")

      prefix = String.slice(step.id, 0, 8)
      assert {:ok, _} = WorkflowSteps.resolve_short_id(user.id, project.id, w1.id, prefix)

      assert {:error, :not_found} =
               WorkflowSteps.resolve_short_id(user.id, project.id, w2.id, prefix)
    end

    test "scopes to project" do
      user = create_user()
      p1 = create_project(user, "Project 1")
      p2 = create_project(user, "Project 2")
      {:ok, w1} = Workflows.insert(user.id, p1.id, %{name: "Workflow 1"})
      step = insert_step(user, p1, w1, "Step")

      prefix = String.slice(step.id, 0, 8)
      assert {:ok, _} = WorkflowSteps.resolve_short_id(user.id, p1.id, w1.id, prefix)

      assert {:error, :not_found} =
               WorkflowSteps.resolve_short_id(user.id, p2.id, w1.id, prefix)
    end

    test "scopes to user" do
      user1 = create_user("1")
      user2 = create_user("2")
      project = create_project(user1)
      {:ok, workflow} = Workflows.insert(user1.id, project.id, %{name: "Workflow"})
      step = insert_step(user1, project, workflow, "Step")

      prefix = String.slice(step.id, 0, 8)
      assert {:ok, _} = WorkflowSteps.resolve_short_id(user1.id, project.id, workflow.id, prefix)

      assert {:error, :not_found} =
               WorkflowSteps.resolve_short_id(user2.id, project.id, workflow.id, prefix)
    end

    test "returns error for invalid prefix" do
      user = create_user()
      project = create_project(user)
      {:ok, workflow} = Workflows.insert(user.id, project.id, %{name: "Test Workflow"})

      assert {:error, :invalid_prefix} =
               WorkflowSteps.resolve_short_id(user.id, project.id, workflow.id, "zzzzzzzz")
    end

    test "returns error for unknown prefix" do
      user = create_user()
      project = create_project(user)
      {:ok, workflow} = Workflows.insert(user.id, project.id, %{name: "Test Workflow"})

      assert {:error, :not_found} =
               WorkflowSteps.resolve_short_id(user.id, project.id, workflow.id, "00000000")
    end
  end
end
