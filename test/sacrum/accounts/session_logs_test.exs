defmodule Sacrum.Accounts.SessionLogsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.SessionLogs
  alias Sacrum.Accounts.StepExecutions
  alias Sacrum.Accounts.Workflows
  alias Sacrum.Accounts.Tasks
  alias Sacrum.Accounts.Projects
  alias Sacrum.Repo.Users

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

  test "derives project ownership and rejects another user's execution" do
    user = create_user()
    {project, execution} = create_step_execution(user)
    other = create_user(%{email: "other@example.com", username: "other", password: "password123"})

    attrs =
      Map.merge(Sacrum.HarnessFixture.attrs("Session started"), %{
        step_execution_id: execution.id,
        project_id: Ecto.UUID.generate()
      })

    assert {:error, :not_found} = SessionLogs.insert(other.id, attrs)
    assert {:ok, log} = SessionLogs.insert(user.id, attrs)
    assert log.project_id == project.id
    assert log.user_id == user.id
    assert log.format == "harness"
    assert log.content == Sacrum.HarnessFixture.content("Session started")
    assert {:error, :not_found} = SessionLogs.insert(user.id, %{})
  end

  describe "get_by/2" do
    test "returns log only if scoped to user" do
      user1 = create_user()
      {project1, execution1} = create_step_execution(user1)

      user2 =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      {project2, execution2} = create_step_execution(user2)

      {:ok, log} =
        SessionLogs.insert(
          user1.id,
          Sacrum.HarnessFixture.with_event(%{
            "step_execution_id" => execution1.id,
            "project_id" => project1.id,
            "content" => "User1 log"
          })
        )

      {:ok, _} =
        SessionLogs.insert(
          user2.id,
          Sacrum.HarnessFixture.with_event(%{
            "step_execution_id" => execution2.id,
            "project_id" => project2.id,
            "content" => "User2 log"
          })
        )

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
        SessionLogs.insert(
          user1.id,
          Sacrum.HarnessFixture.with_event(%{
            "step_execution_id" => execution1.id,
            "project_id" => project1.id,
            "content" => "User1 log"
          })
        )

      {:ok, _} =
        SessionLogs.insert(
          user2.id,
          Sacrum.HarnessFixture.with_event(%{
            "step_execution_id" => execution2.id,
            "project_id" => project2.id,
            "content" => "User2 log"
          })
        )

      logs = SessionLogs.list_by(user1.id)
      assert length(logs) == 1
      assert hd(logs).user_id == user1.id
    end
  end
end
