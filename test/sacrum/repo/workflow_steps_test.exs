defmodule Sacrum.Repo.WorkflowStepsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.WorkflowSteps
  alias Sacrum.Repo.Workflows
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Schemas.WorkflowStep

  @valid_user_attrs %{
    email: "test@example.com",
    username: "testuser",
    password: "password123"
  }

  @valid_attrs %{
    name: "Review",
    goal: "Review the implementation",
    agents: ["reviewer"],
    skills: ["code-review"],
    agent_config: %{"timeout" => 300},
    step_order: 1
  }

  defp create_workflow do
    {:ok, user} = Users.insert(@valid_user_attrs)
    {:ok, project} = Projects.insert(user, %{name: "My Project"})
    {:ok, workflow} = Workflows.insert(project, %{name: "Default"})
    workflow
  end

  describe "insert/2" do
    test "creates step with valid attrs" do
      workflow = create_workflow()
      assert {:ok, %WorkflowStep{} = step} = WorkflowSteps.insert(workflow, @valid_attrs)
      assert step.name == "Review"
      assert step.goal == "Review the implementation"
      assert step.agents == ["reviewer"]
      assert step.skills == ["code-review"]
      assert step.agent_config == %{"timeout" => 300}
      assert step.step_order == 1
      assert step.is_final == false
      assert step.workflow_id == workflow.id
    end

    test "accepts workflow_id as binary" do
      workflow = create_workflow()
      assert {:ok, %WorkflowStep{}} = WorkflowSteps.insert(workflow.id, @valid_attrs)
    end

    test "rejects missing name" do
      workflow = create_workflow()
      assert {:error, changeset} = WorkflowSteps.insert(workflow, %{})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "list/1" do
    test "returns steps for a workflow ordered by step_order" do
      workflow = create_workflow()
      {:ok, s2} = WorkflowSteps.insert(workflow, %{name: "Second", step_order: 2})
      {:ok, s1} = WorkflowSteps.insert(workflow, %{name: "First", step_order: 1})

      steps = WorkflowSteps.list(workflow)
      assert length(steps) == 2
      assert Enum.map(steps, & &1.id) == [s1.id, s2.id]
    end

    test "returns empty list when workflow has no steps" do
      workflow = create_workflow()
      assert [] = WorkflowSteps.list(workflow)
    end
  end

  describe "get/1" do
    test "returns step by ID" do
      workflow = create_workflow()
      {:ok, step} = WorkflowSteps.insert(workflow, @valid_attrs)
      assert {:ok, found} = WorkflowSteps.get(step.id)
      assert found.id == step.id
    end

    test "returns error when not found" do
      assert {:error, :not_found} = WorkflowSteps.get(Ecto.UUID.generate())
    end
  end

  describe "update/2" do
    test "updates step fields" do
      workflow = create_workflow()
      {:ok, step} = WorkflowSteps.insert(workflow, @valid_attrs)

      assert {:ok, updated} =
               WorkflowSteps.update(step, %{name: "Updated", goal: "New goal", is_final: true})

      assert updated.name == "Updated"
      assert updated.goal == "New goal"
      assert updated.is_final == true
    end
  end

  describe "delete/1" do
    test "removes the step" do
      workflow = create_workflow()
      {:ok, step} = WorkflowSteps.insert(workflow, @valid_attrs)
      assert {:ok, _} = WorkflowSteps.delete(step)
      assert {:error, :not_found} = WorkflowSteps.get(step.id)
    end
  end
end
