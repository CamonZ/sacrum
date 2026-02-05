defmodule Sacrum.Accounts.SessionLogsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.SessionLogs
  alias Sacrum.Accounts.StepExecutions
  alias Sacrum.Accounts.Workflows
  alias Sacrum.Accounts.Tasks
  alias Sacrum.Accounts.Projects
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Schemas.SessionLog

  @valid_user_attrs %{
    email: "test@example.com",
    username: "testuser",
    password: "password123"
  }

  defp create_user(attrs \\ @valid_user_attrs) do
    {:ok, user} = Users.insert(attrs)
    user
  end

  defp create_step_execution(user) do
    {:ok, project} = Projects.insert(user.id, %{name: "Test Project"})
    {:ok, workflow} = Workflows.insert(user.id, project.id, %{name: "Test Workflow"})
    {:ok, task} = Tasks.insert(user.id, project.id, %{title: "Test Task"})

    {:ok, execution} =
      StepExecutions.insert(user.id, %{
        "task_id" => task.id,
        "project_id" => project.id,
        "workflow_id" => workflow.id,
        "step_name" => "In Progress",
        "status" => "in_progress"
      })

    {project, execution}
  end

  describe "insert/2" do
    test "creates session log scoped to user_id, project_id, and step_execution_id" do
      user = create_user()
      {project, execution} = create_step_execution(user)

      assert {:ok, %SessionLog{} = log} =
               SessionLogs.insert(user.id, %{
                 "step_execution_id" => execution.id,
                 "project_id" => project.id,
                 "content" => "Session started"
               })

      assert log.user_id == user.id
      assert log.project_id == project.id
      assert log.step_execution_id == execution.id
      assert log.content == "Session started"
    end
  end

  describe "get_by/2" do
    test "returns log only if scoped to user" do
      user1 = create_user()
      {project1, execution1} = create_step_execution(user1)

      user2 =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      {project2, execution2} = create_step_execution(user2)

      {:ok, log} =
        SessionLogs.insert(user1.id, %{
          "step_execution_id" => execution1.id,
          "project_id" => project1.id,
          "content" => "User1 log"
        })

      {:ok, _} =
        SessionLogs.insert(user2.id, %{
          "step_execution_id" => execution2.id,
          "project_id" => project2.id,
          "content" => "User2 log"
        })

      # User1 can access their log
      assert {:ok, found} = SessionLogs.get_by(user1.id, conditions: [id: log.id])
      assert found.id == log.id
      assert found.user_id == user1.id

      # User2 cannot access user1's log
      assert {:error, :not_found} = SessionLogs.get_by(user2.id, conditions: [id: log.id])
    end
  end

  describe "list_by/2" do
    test "returns only logs scoped to user" do
      user1 = create_user()
      {project1, execution1} = create_step_execution(user1)

      user2 =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      {project2, execution2} = create_step_execution(user2)

      {:ok, _} =
        SessionLogs.insert(user1.id, %{
          "step_execution_id" => execution1.id,
          "project_id" => project1.id,
          "content" => "User1 log"
        })

      {:ok, _} =
        SessionLogs.insert(user2.id, %{
          "step_execution_id" => execution2.id,
          "project_id" => project2.id,
          "content" => "User2 log"
        })

      logs = SessionLogs.list_by(user1.id)
      assert length(logs) == 1
      assert hd(logs).user_id == user1.id
    end
  end
end
