defmodule Sacrum.PendingExecutionTimeoutCheckerTest do
  use Sacrum.DataCase

  alias Sacrum.Accounts
  alias Sacrum.PendingExecutionTimeoutChecker
  alias Sacrum.Repo

  setup do
    # Get the current timeout setting and restore it after the test
    original_timeout = Application.get_env(:sacrum, :pending_execution_timeout_ms, 60_000)

    on_exit(fn ->
      Application.put_env(:sacrum, :pending_execution_timeout_ms, original_timeout)
    end)

    :ok
  end

  describe "timeout checking" do
    test "marks old pending executions as failed with timeout message" do
      {:ok, user} = Sacrum.Repo.Users.insert(%{email: "user1@example.com", username: "user1", password: "password123"})
      {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Test Project"})
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Test Task"})
      {:ok, workflow} = Accounts.Workflows.insert(user.id, project.id, %{name: "Test Workflow"})

      # Create a pending execution with an old inserted_at timestamp
      {:ok, old_execution} =
        Accounts.StepExecutions.insert(user.id, %{
          task_id: task.id,
          workflow_id: workflow.id,
          project_id: project.id,
          step_name: "Test Step",
          status: "pending"
        })

      # Manually update the inserted_at to be in the past
      # Set timeout to 1 second, and make the execution 2 seconds old
      Application.put_env(:sacrum, :pending_execution_timeout_ms, 1_000)

      old_time = DateTime.add(DateTime.utc_now(), -2_000, :millisecond)

      {:ok, _} =
        old_execution
        |> Ecto.Changeset.change(inserted_at: old_time)
        |> Repo.update()

      # Manually trigger the timeout check
      # (In production this happens via the periodic timer)
      send(PendingExecutionTimeoutChecker, :check_timeouts)

      # Give the timeout checker a moment to process
      Process.sleep(100)

      # Verify the execution was marked as failed
      {:ok, updated_execution} = Accounts.StepExecutions.get_by(user.id, conditions: [id: old_execution.id])
      assert updated_execution.status == "failed"
      assert String.contains?(String.downcase(updated_execution.output), "no daemon picked up")
    end

    test "does not mark recent pending executions as failed" do
      {:ok, user} = Sacrum.Repo.Users.insert(%{email: "user2@example.com", username: "user2", password: "password123"})
      {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Test Project"})
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Test Task"})
      {:ok, workflow} = Accounts.Workflows.insert(user.id, project.id, %{name: "Test Workflow"})

      # Create a recent pending execution
      {:ok, recent_execution} =
        Accounts.StepExecutions.insert(user.id, %{
          task_id: task.id,
          workflow_id: workflow.id,
          project_id: project.id,
          step_name: "Test Step",
          status: "pending"
        })

      # Set timeout to 60 seconds
      Application.put_env(:sacrum, :pending_execution_timeout_ms, 60_000)

      # Manually trigger the timeout check
      send(PendingExecutionTimeoutChecker, :check_timeouts)

      # Give the timeout checker a moment to process
      Process.sleep(100)

      # Verify the execution is still pending
      {:ok, updated_execution} =
        Accounts.StepExecutions.get_by(user.id, conditions: [id: recent_execution.id])

      assert updated_execution.status == "pending"
    end

    test "does not mark running executions as failed" do
      {:ok, user} = Sacrum.Repo.Users.insert(%{email: "user3@example.com", username: "user3", password: "password123"})
      {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Test Project"})
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Test Task"})
      {:ok, workflow} = Accounts.Workflows.insert(user.id, project.id, %{name: "Test Workflow"})

      # Create a running execution with an old inserted_at timestamp
      {:ok, old_execution} =
        Accounts.StepExecutions.insert(user.id, %{
          task_id: task.id,
          workflow_id: workflow.id,
          project_id: project.id,
          step_name: "Test Step",
          status: "running"
        })

      # Update inserted_at to be in the past
      Application.put_env(:sacrum, :pending_execution_timeout_ms, 1_000)

      old_time = DateTime.add(DateTime.utc_now(), -2_000, :millisecond)

      {:ok, _} =
        old_execution
        |> Ecto.Changeset.change(inserted_at: old_time)
        |> Repo.update()

      # Manually trigger the timeout check
      send(PendingExecutionTimeoutChecker, :check_timeouts)

      # Give the timeout checker a moment to process
      Process.sleep(100)

      # Verify the execution is still running
      {:ok, updated_execution} =
        Accounts.StepExecutions.get_by(user.id, conditions: [id: old_execution.id])

      assert updated_execution.status == "running"
    end

    test "marks multiple old pending executions as failed" do
      {:ok, user} = Sacrum.Repo.Users.insert(%{email: "user4@example.com", username: "user4", password: "password123"})
      {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Test Project"})
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Test Task"})
      {:ok, workflow} = Accounts.Workflows.insert(user.id, project.id, %{name: "Test Workflow"})

      # Create multiple pending executions
      {:ok, exec1} =
        Accounts.StepExecutions.insert(user.id, %{
          task_id: task.id,
          workflow_id: workflow.id,
          project_id: project.id,
          step_name: "Step 1",
          status: "pending"
        })

      {:ok, exec2} =
        Accounts.StepExecutions.insert(user.id, %{
          task_id: task.id,
          workflow_id: workflow.id,
          project_id: project.id,
          step_name: "Step 2",
          status: "pending"
        })

      # Set timeout and update inserted_at for both
      Application.put_env(:sacrum, :pending_execution_timeout_ms, 1_000)
      old_time = DateTime.add(DateTime.utc_now(), -2_000, :millisecond)

      {:ok, _} =
        exec1
        |> Ecto.Changeset.change(inserted_at: old_time)
        |> Repo.update()

      {:ok, _} =
        exec2
        |> Ecto.Changeset.change(inserted_at: old_time)
        |> Repo.update()

      # Manually trigger the timeout check
      send(PendingExecutionTimeoutChecker, :check_timeouts)

      # Give the timeout checker a moment to process
      Process.sleep(100)

      # Verify both executions were marked as failed
      {:ok, updated_exec1} = Accounts.StepExecutions.get_by(user.id, conditions: [id: exec1.id])
      {:ok, updated_exec2} = Accounts.StepExecutions.get_by(user.id, conditions: [id: exec2.id])

      assert updated_exec1.status == "failed"
      assert updated_exec2.status == "failed"
    end
  end
end
