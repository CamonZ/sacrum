defmodule Sacrum.Accounts.StepExecutionsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.StepExecutions
  alias Sacrum.Accounts.TaskRuns
  alias Sacrum.Accounts.WorkflowSteps
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

    test "casts expanded token counters and preserves zero values" do
      user = create_user()
      {project, task, workflow} = create_task_with_workflow(user)

      assert {:ok, %StepExecution{} = execution} =
               StepExecutions.insert(user.id, %{
                 "task_id" => task.id,
                 "project_id" => project.id,
                 "workflow_id" => workflow.id,
                 "step_name" => "In Progress",
                 "session_input_tokens" => 0,
                 "session_cache_read_input_tokens" => 30,
                 "session_output_tokens" => 10,
                 "session_total_tokens" => 40,
                 "context_window_input_tokens" => 0,
                 "context_window_cache_read_input_tokens" => 30,
                 "context_window_total_tokens" => 40
               })

      assert execution.session_input_tokens == 0
      assert execution.session_cache_read_input_tokens == 30
      assert execution.session_output_tokens == 10
      assert execution.session_total_tokens == 40
      assert execution.context_window_input_tokens == 0
      assert execution.context_window_cache_read_input_tokens == 30
      assert execution.context_window_total_tokens == 40
    end

    test "derives step_type from string-keyed step_id attrs and returns changeset on spoof" do
      user = create_user()
      {project, task, workflow} = create_task_with_workflow(user)

      {:ok, step} =
        WorkflowSteps.insert(workflow, %{
          name: "Human Input",
          step_type: "human_input"
        })

      attrs = %{
        "task_id" => task.id,
        "project_id" => project.id,
        "workflow_id" => workflow.id,
        "step_id" => step.id,
        "step_name" => "Human Input",
        "step_type" => "execute"
      }

      assert {:error, changeset} = StepExecutions.insert(user.id, attrs)
      assert %{step_type: ["must match the referenced workflow step"]} = errors_on(changeset)
    end

    test "rejects step_id from a different workflow" do
      user = create_user()
      {project, task, workflow} = create_task_with_workflow(user)
      {:ok, other_workflow} = Workflows.insert(user.id, project.id, %{name: "Other Workflow"})

      {:ok, other_step} =
        WorkflowSteps.insert(other_workflow, %{
          name: "Other Step",
          step_type: "route"
        })

      assert {:error, changeset} =
               StepExecutions.insert(user.id, %{
                 task_id: task.id,
                 project_id: project.id,
                 workflow_id: workflow.id,
                 step_id: other_step.id,
                 step_name: "Other Step"
               })

      assert %{step_id: ["must belong to the referenced workflow"]} = errors_on(changeset)
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

  describe "update/2" do
    test "updates step execution fields" do
      user = create_user()
      {project, task, workflow} = create_task_with_workflow(user)

      {:ok, execution} =
        StepExecutions.insert(user.id, %{
          "task_id" => task.id,
          "project_id" => project.id,
          "workflow_id" => workflow.id,
          "step_name" => "draft",
          "status" => "in_progress"
        })

      assert {:ok, %StepExecution{} = updated} =
               StepExecutions.update(execution, %{
                 "status" => "completed",
                 "output" => "Done",
                 "output_tokens" => 42
               })

      assert updated.id == execution.id
      assert updated.status == "completed"
      assert updated.output == "Done"
      assert updated.output_tokens == 42
      # unchanged fields preserved
      assert updated.step_name == "draft"
      assert updated.task_id == task.id
    end

    test "updates expanded token counters and preserves zero values" do
      user = create_user()
      {project, task, workflow} = create_task_with_workflow(user)

      {:ok, execution} =
        StepExecutions.insert(user.id, %{
          "task_id" => task.id,
          "project_id" => project.id,
          "workflow_id" => workflow.id,
          "step_name" => "draft"
        })

      assert {:ok, updated} =
               StepExecutions.update(execution, %{
                 "session_input_tokens" => 150,
                 "session_cache_read_input_tokens" => 0,
                 "session_output_tokens" => 40,
                 "session_total_tokens" => 190,
                 "context_window_input_tokens" => 150,
                 "context_window_cache_read_input_tokens" => 0,
                 "context_window_total_tokens" => 190
               })

      assert updated.session_input_tokens == 150
      assert updated.session_cache_read_input_tokens == 0
      assert updated.session_output_tokens == 40
      assert updated.session_total_tokens == 190
      assert updated.context_window_input_tokens == 150
      assert updated.context_window_cache_read_input_tokens == 0
      assert updated.context_window_total_tokens == 190
    end

    test "does not allow changing task_id" do
      user = create_user()
      {project, task, workflow} = create_task_with_workflow(user)

      {:ok, execution} =
        StepExecutions.insert(user.id, %{
          "task_id" => task.id,
          "project_id" => project.id,
          "workflow_id" => workflow.id,
          "step_name" => "draft",
          "status" => "in_progress"
        })

      other_task_id = Ecto.UUID.generate()

      {:ok, updated} =
        StepExecutions.update(execution, %{"task_id" => other_task_id})

      assert updated.task_id == task.id
    end

    test "returns error changeset for invalid data" do
      user = create_user()
      {project, task, workflow} = create_task_with_workflow(user)

      {:ok, execution} =
        StepExecutions.insert(user.id, %{
          "task_id" => task.id,
          "project_id" => project.id,
          "workflow_id" => workflow.id,
          "step_name" => "draft",
          "status" => "in_progress"
        })

      assert {:error, changeset} =
               StepExecutions.update(execution, %{"step_name" => nil})

      assert %{step_name: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects completing or filling a waiting human_input execution" do
      user = create_user()
      {project, task, workflow} = create_task_with_workflow(user)

      {:ok, step} =
        WorkflowSteps.insert(user.id, %{
          "workflow_id" => workflow.id,
          "project_id" => project.id,
          "name" => "Human Input",
          "step_type" => "human_input"
        })

      {:ok, execution} =
        StepExecutions.insert(user.id, %{
          "task_id" => task.id,
          "project_id" => project.id,
          "workflow_id" => workflow.id,
          "step_id" => step.id,
          "step_name" => step.name,
          "status" => "waiting"
        })

      assert {:error, changeset} =
               StepExecutions.update(execution, %{
                 "status" => "completed",
                 "output" => ~s({"approved":true})
               })

      assert %{
               status: [
                 "waiting human_input executions can only be completed by the human input resume operation"
               ]
             } = errors_on(changeset)

      reloaded = Sacrum.Repo.get!(StepExecution, execution.id)
      assert reloaded.status == "waiting"
      assert reloaded.output == nil
    end
  end

  describe "complete_waiting_human_input/3" do
    test "consumes a waiting human_input execution once and leaves a recoverable queued run" do
      user = create_user()
      {project, task, workflow} = create_task_with_workflow(user)

      {:ok, step} =
        WorkflowSteps.insert(user.id, %{
          "workflow_id" => workflow.id,
          "project_id" => project.id,
          "name" => "Human Input",
          "step_type" => "human_input"
        })

      {:ok, task_run} =
        TaskRuns.insert(user.id, project.id, task.id, %{status: :waiting})

      {:ok, execution} =
        StepExecutions.insert(user.id, %{
          "task_id" => task.id,
          "task_run_id" => task_run.id,
          "project_id" => project.id,
          "workflow_id" => workflow.id,
          "step_id" => step.id,
          "step_name" => step.name,
          "status" => "waiting"
        })

      encoded_output = ~s({"approved":true})

      assert {:ok, %{execution: completed, task_run: queued_run}} =
               StepExecutions.complete_waiting_human_input(
                 user.id,
                 execution.id,
                 encoded_output
               )

      assert completed.id == execution.id
      assert completed.status == "completed"
      assert completed.output == encoded_output
      assert queued_run.id == task_run.id
      assert queued_run.status == :queued
      assert queued_run.latest_step_execution_id == execution.id

      assert {:ok, %{execution: same_execution, task_run: same_run}} =
               StepExecutions.complete_waiting_human_input(
                 user.id,
                 execution.id,
                 encoded_output
               )

      assert same_execution.id == execution.id
      assert same_execution.output == encoded_output
      assert same_run.status == :queued

      assert {:error, :human_input_execution_not_waiting} =
               StepExecutions.complete_waiting_human_input(
                 user.id,
                 execution.id,
                 ~s({"approved":false})
               )

      reloaded = Sacrum.Repo.get!(StepExecution, execution.id)
      assert reloaded.status == "completed"
      assert reloaded.output == encoded_output
    end
  end
end
