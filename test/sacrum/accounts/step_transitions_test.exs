defmodule Sacrum.Accounts.StepTransitionsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.StepTransitions
  alias Sacrum.Accounts.WorkflowSteps
  alias Sacrum.Accounts.Workflows
  alias Sacrum.Accounts.Projects
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Schemas.StepTransition

  @valid_user_attrs %{
    email: "test@example.com",
    username: "testuser",
    password: "password123"
  }

  defp create_user(attrs \\ @valid_user_attrs) do
    {:ok, user} = Users.insert(attrs)
    user
  end

  defp create_workflow_with_steps(user) do
    {:ok, project} = Projects.insert(user.id, %{name: "Test Project"})
    {:ok, workflow} = Workflows.insert(user.id, project.id, %{name: "Test Workflow"})
    {:ok, step1} = WorkflowSteps.insert(workflow, %{name: "Backlog"})
    {:ok, step2} = WorkflowSteps.insert(workflow, %{name: "In Progress"})
    {project, step1, step2}
  end

  describe "insert/2" do
    test "creates step transition scoped to user_id, project_id, and step ids" do
      user = create_user()
      {project, step1, step2} = create_workflow_with_steps(user)

      assert {:ok, %StepTransition{} = transition} =
               StepTransitions.insert(user.id, %{
                 "from_step_id" => step1.id,
                 "to_step_id" => step2.id,
                 "project_id" => project.id
               })

      assert transition.user_id == user.id
      assert transition.project_id == project.id
      assert transition.from_step_id == step1.id
      assert transition.to_step_id == step2.id
    end
  end

  describe "get_by/2" do
    test "returns transition only if scoped to user" do
      user1 = create_user()
      {project1, step1a, step1b} = create_workflow_with_steps(user1)

      user2 =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      {project2, step2a, step2b} = create_workflow_with_steps(user2)

      {:ok, transition} =
        StepTransitions.insert(user1.id, %{
          "from_step_id" => step1a.id,
          "to_step_id" => step1b.id,
          "project_id" => project1.id
        })

      {:ok, _} =
        StepTransitions.insert(user2.id, %{
          "from_step_id" => step2a.id,
          "to_step_id" => step2b.id,
          "project_id" => project2.id
        })

      # User1 can access their transition
      assert {:ok, found} = StepTransitions.get_by(user1.id, conditions: [id: transition.id])
      assert found.id == transition.id
      assert found.user_id == user1.id

      # User2 cannot access user1's transition
      assert {:error, :not_found} =
               StepTransitions.get_by(user2.id, conditions: [id: transition.id])
    end
  end

  describe "list_by/2" do
    test "returns only transitions scoped to user" do
      user1 = create_user()
      {project1, step1a, step1b} = create_workflow_with_steps(user1)

      user2 =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      {project2, step2a, step2b} = create_workflow_with_steps(user2)

      {:ok, _} =
        StepTransitions.insert(user1.id, %{
          "from_step_id" => step1a.id,
          "to_step_id" => step1b.id,
          "project_id" => project1.id
        })

      {:ok, _} =
        StepTransitions.insert(user2.id, %{
          "from_step_id" => step2a.id,
          "to_step_id" => step2b.id,
          "project_id" => project2.id
        })

      transitions = StepTransitions.list_by(user1.id)
      assert length(transitions) == 1
      assert hd(transitions).user_id == user1.id
    end
  end
end
