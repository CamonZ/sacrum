defmodule Sacrum.Accounts.StepExecutionsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.StepExecutions
  alias Sacrum.Accounts.Workflows
  alias Sacrum.Accounts.Tasks
  alias Sacrum.Accounts.Projects
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Schemas.StepExecution

  @valid_user_attrs %{
    email: "test@example.com",
    username: "testuser",
    password: "password123"
  }

  defp create_user(attrs \\ @valid_user_attrs) do
    {:ok, user} = Users.insert(attrs)
    user
  end

  defp create_task_with_workflow(user) do
    {:ok, project} = Projects.insert(user.id, %{name: "Test Project"})
    {:ok, workflow} = Workflows.insert(user.id, project.id, %{name: "Test Workflow"})
    {:ok, task} = Tasks.insert(user.id, project.id, %{title: "Test Task"})
    {project, task, workflow}
  end

  describe "insert/2" do
    test "creates step execution scoped to user_id, project_id, and task_id" do
      user = create_user()
      {project, task, workflow} = create_task_with_workflow(user)

      assert {:ok, %StepExecution{} = execution} =
               StepExecutions.insert(user.id, %{
                 "task_id" => task.id,
                 "project_id" => project.id,
                 "workflow_id" => workflow.id,
                 "step_name" => "In Progress",
                 "status" => "in_progress"
               })

      assert execution.user_id == user.id
      assert execution.project_id == project.id
      assert execution.task_id == task.id
      assert execution.step_name == "In Progress"
    end
  end

  describe "get_by/2" do
    test "returns execution only if scoped to user" do
      user1 = create_user()
      {project1, task1, workflow1} = create_task_with_workflow(user1)

      user2 =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      {project2, task2, workflow2} = create_task_with_workflow(user2)

      {:ok, execution} =
        StepExecutions.insert(user1.id, %{
          "task_id" => task1.id,
          "project_id" => project1.id,
          "workflow_id" => workflow1.id,
          "step_name" => "In Progress",
          "status" => "in_progress"
        })

      {:ok, _} =
        StepExecutions.insert(user2.id, %{
          "task_id" => task2.id,
          "project_id" => project2.id,
          "workflow_id" => workflow2.id,
          "step_name" => "In Progress",
          "status" => "in_progress"
        })

      # User1 can access their execution
      assert {:ok, found} = StepExecutions.get_by(user1.id, conditions: [id: execution.id])
      assert found.id == execution.id
      assert found.user_id == user1.id

      # User2 cannot access user1's execution
      assert {:error, :not_found} =
               StepExecutions.get_by(user2.id, conditions: [id: execution.id])
    end
  end

  describe "list_by/2" do
    test "returns only executions scoped to user" do
      user1 = create_user()
      {project1, task1, workflow1} = create_task_with_workflow(user1)

      user2 =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      {project2, task2, workflow2} = create_task_with_workflow(user2)

      {:ok, _} =
        StepExecutions.insert(user1.id, %{
          "task_id" => task1.id,
          "project_id" => project1.id,
          "workflow_id" => workflow1.id,
          "step_name" => "In Progress",
          "status" => "in_progress"
        })

      {:ok, _} =
        StepExecutions.insert(user2.id, %{
          "task_id" => task2.id,
          "project_id" => project2.id,
          "workflow_id" => workflow2.id,
          "step_name" => "In Progress",
          "status" => "in_progress"
        })

      executions = StepExecutions.list_by(user1.id)
      assert length(executions) == 1
      assert hd(executions).user_id == user1.id
    end
  end
end
