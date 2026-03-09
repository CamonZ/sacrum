defmodule Sacrum.Accounts.WorkflowStepsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.WorkflowSteps
  alias Sacrum.Accounts.Workflows
  alias Sacrum.Accounts.Projects
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Schemas.WorkflowStep

  @valid_user_attrs %{
    email: "test@example.com",
    username: "testuser",
    password: "password123"
  }

  defp create_user(attrs \\ @valid_user_attrs) do
    {:ok, user} = Users.insert(attrs)
    user
  end

  defp create_workflow(user) do
    {:ok, project} = Projects.insert(user.id, %{name: "Test Project"})
    {:ok, workflow} = Workflows.insert(user.id, project.id, %{name: "Test Workflow"})
    {project, workflow}
  end

  describe "insert/2 with attrs" do
    test "creates step scoped to user_id, project_id, and workflow_id" do
      user = create_user()
      {project, workflow} = create_workflow(user)

      assert {:ok, %WorkflowStep{} = step} =
               WorkflowSteps.insert(user.id, %{
                 "workflow_id" => workflow.id,
                 "project_id" => project.id,
                 "name" => "Draft"
               })

      assert step.user_id == user.id
      assert step.project_id == project.id
      assert step.workflow_id == workflow.id
      assert step.name == "Draft"
    end

    test "accepts workflow struct and extracts ids" do
      user = create_user()
      {project, workflow} = create_workflow(user)

      assert {:ok, %WorkflowStep{} = step} =
               WorkflowSteps.insert(workflow, %{name: "Draft"})

      assert step.user_id == user.id
      assert step.project_id == project.id
      assert step.workflow_id == workflow.id
    end
  end

  describe "get_by/2" do
    test "returns step only if scoped to user" do
      user1 = create_user()
      {_project1, workflow1} = create_workflow(user1)

      user2 =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      {_project2, workflow2} = create_workflow(user2)

      {:ok, step} = WorkflowSteps.insert(workflow1, %{name: "User1 Step"})
      {:ok, _} = WorkflowSteps.insert(workflow2, %{name: "User2 Step"})

      # User1 can access their step
      assert {:ok, found} = WorkflowSteps.get_by(user1.id, conditions: [id: step.id])
      assert found.id == step.id
      assert found.user_id == user1.id

      # User2 cannot access user1's step
      assert {:error, :not_found} = WorkflowSteps.get_by(user2.id, conditions: [id: step.id])
    end
  end

  describe "list_by/2" do
    test "returns only steps scoped to user" do
      user1 = create_user()
      {_project1, workflow1} = create_workflow(user1)

      user2 =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      {_project2, workflow2} = create_workflow(user2)

      {:ok, _} = WorkflowSteps.insert(workflow1, %{name: "User1 Step"})
      {:ok, _} = WorkflowSteps.insert(workflow2, %{name: "User2 Step"})

      steps = WorkflowSteps.list_by(user1.id)
      assert length(steps) == 1
      assert hd(steps).user_id == user1.id
    end

    test "filters by workflow_id" do
      user = create_user()
      {project, workflow1} = create_workflow(user)
      {:ok, workflow2} = Workflows.insert(user.id, project.id, %{name: "Workflow 2"})

      {:ok, _} = WorkflowSteps.insert(workflow1, %{name: "Step 1"})
      {:ok, _} = WorkflowSteps.insert(workflow2, %{name: "Step 2"})

      steps = WorkflowSteps.list_by(user.id, conditions: [workflow_id: workflow1.id])
      assert length(steps) == 1
      assert hd(steps).workflow_id == workflow1.id
    end
  end

  describe "prompt and eval_prompt fields" do
    test "inserts step with prompt and eval_prompt" do
      user = create_user()
      {_project, workflow} = create_workflow(user)

      assert {:ok, %WorkflowStep{} = step} =
               WorkflowSteps.insert(workflow, %{
                 name: "Review",
                 prompt: "Please review the following content",
                 eval_prompt: "Is the content complete and accurate?"
               })

      assert step.prompt == "Please review the following content"
      assert step.eval_prompt == "Is the content complete and accurate?"
    end

    test "updates step with prompt and eval_prompt" do
      user = create_user()
      {_project, workflow} = create_workflow(user)

      {:ok, step} = WorkflowSteps.insert(workflow, %{name: "Review"})

      assert {:ok, updated_step} =
               WorkflowSteps.update(step, %{
                 prompt: "Updated prompt",
                 eval_prompt: "Updated eval prompt"
               })

      assert updated_step.prompt == "Updated prompt"
      assert updated_step.eval_prompt == "Updated eval prompt"
    end

    test "handles optional prompt and eval_prompt fields" do
      user = create_user()
      {_project, workflow} = create_workflow(user)

      # Create without prompt and eval_prompt
      assert {:ok, step} = WorkflowSteps.insert(workflow, %{name: "Review"})
      assert is_nil(step.prompt)
      assert is_nil(step.eval_prompt)

      # Update to add them
      assert {:ok, updated_step} =
               WorkflowSteps.update(step, %{prompt: "New prompt"})

      assert updated_step.prompt == "New prompt"
      assert is_nil(updated_step.eval_prompt)
    end
  end
end
