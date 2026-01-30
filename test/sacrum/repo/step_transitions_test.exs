defmodule Sacrum.Repo.StepTransitionsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.StepTransitions
  alias Sacrum.Repo.WorkflowSteps
  alias Sacrum.Repo.Workflows
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Schemas.StepTransition

  @valid_user_attrs %{
    email: "test@example.com",
    username: "testuser",
    password: "password123"
  }

  defp create_steps do
    {:ok, user} = Users.insert(@valid_user_attrs)
    {:ok, project} = Projects.insert(user, %{name: "My Project"})
    {:ok, workflow} = Workflows.insert(project, %{name: "Default"})
    {:ok, step1} = WorkflowSteps.insert(workflow, %{name: "Draft", step_order: 1})
    {:ok, step2} = WorkflowSteps.insert(workflow, %{name: "Review", step_order: 2})
    {project, workflow, step1, step2}
  end

  describe "insert/1" do
    test "creates transition between two steps in same workflow" do
      {_project, _workflow, step1, step2} = create_steps()

      assert {:ok, %StepTransition{} = transition} =
               StepTransitions.insert(step1.user_id, %{
                 from_step_id: step1.id,
                 to_step_id: step2.id,
                 label: "submit"
               })

      assert transition.from_step_id == step1.id
      assert transition.to_step_id == step2.id
      assert transition.label == "submit"
    end

    test "rejects transition between steps in different workflows" do
      {:ok, user} = Users.insert(@valid_user_attrs)
      {:ok, project} = Projects.insert(user, %{name: "My Project"})
      {:ok, workflow1} = Workflows.insert(project, %{name: "Workflow 1"})
      {:ok, workflow2} = Workflows.insert(project, %{name: "Workflow 2"})
      {:ok, step1} = WorkflowSteps.insert(workflow1, %{name: "Step A"})
      {:ok, step2} = WorkflowSteps.insert(workflow2, %{name: "Step B"})

      assert {:error, :different_workflows} =
               StepTransitions.insert(step1.user_id, %{
                 from_step_id: step1.id,
                 to_step_id: step2.id
               })
    end

    test "rejects duplicate from_step/to_step pair" do
      {_project, _workflow, step1, step2} = create_steps()

      {:ok, _} =
        StepTransitions.insert(step1.user_id, %{from_step_id: step1.id, to_step_id: step2.id})

      assert {:error, changeset} =
               StepTransitions.insert(step1.user_id, %{
                 from_step_id: step1.id,
                 to_step_id: step2.id
               })

      assert %{from_step_id: ["transition already exists between these steps"]} =
               errors_on(changeset)
    end
  end

  describe "list_for_step/1" do
    test "returns transitions from a step" do
      {_project, _workflow, step1, step2} = create_steps()

      {:ok, _} =
        StepTransitions.insert(step1.user_id, %{from_step_id: step1.id, to_step_id: step2.id})

      transitions = StepTransitions.list_for_step(step1)
      assert length(transitions) == 1
      assert hd(transitions).to_step_id == step2.id
    end
  end

  describe "delete/1" do
    test "removes the transition" do
      {_project, _workflow, step1, step2} = create_steps()

      {:ok, transition} =
        StepTransitions.insert(step1.user_id, %{from_step_id: step1.id, to_step_id: step2.id})

      assert {:ok, _} = StepTransitions.delete(transition)
      assert {:error, :not_found} = StepTransitions.get(transition.id)
    end
  end
end
