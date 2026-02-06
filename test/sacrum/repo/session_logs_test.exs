defmodule Sacrum.Repo.SessionLogsTest do
  use Sacrum.DataCase, async: false

  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Workflows
  alias Sacrum.Repo.SessionLogs
  alias Sacrum.Repo.StepExecutions
  alias Sacrum.Repo.Tasks
  alias Sacrum.Repo.Schemas.SessionLog

  @valid_user_attrs %{
    email: "test@example.com",
    username: "testuser",
    password: "password123"
  }

  defp create_user do
    {:ok, user} = Users.insert(@valid_user_attrs)
    user
  end

  defp create_execution do
    unique_id = System.unique_integer([:positive]) |> Integer.to_string()
    email = "user#{unique_id}@example.com"
    username = "user#{unique_id}"
    user = create_user_with_email_and_username(email, username)
    {:ok, project} = Projects.insert(user, %{name: "Test Project #{unique_id}"})
    {:ok, _workflow} = Workflows.insert(project, %{name: "Default"})
    {:ok, task} = Tasks.insert(project.id, user.id, %{title: "Test Task"})

    {:ok, execution} =
      StepExecutions.insert(user.id, %{
        project_id: project.id,
        task_id: task.id,
        step_name: "review"
      })

    {execution, project}
  end

  defp create_user_with_email_and_username(email, username) do
    {:ok, user} = Users.insert(%{@valid_user_attrs | email: email, username: username})
    user
  end

  describe "insert/1" do
    test "creates session log record" do
      {execution, project} = create_execution()
      user_id = execution.user_id

      assert {:ok, %SessionLog{} = log} =
               SessionLogs.insert(user_id, %{
                 project_id: project.id,
                 step_execution_id: execution.id,
                 content: "Reviewing code changes..."
               })

      assert log.content == "Reviewing code changes..."
      assert log.step_execution_id == execution.id
    end

    test "rejects missing content" do
      {execution, project} = create_execution()
      user_id = execution.user_id

      assert {:error, changeset} =
               SessionLogs.insert(user_id, %{
                 project_id: project.id,
                 step_execution_id: execution.id
               })

      assert %{content: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects missing step_execution_id" do
      user = create_user()
      {:ok, project} = Projects.insert(user, %{name: "Test Project"})

      assert {:error, changeset} =
               SessionLogs.insert(user.id, %{project_id: project.id, content: "Some log"})

      assert %{step_execution_id: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "all/1" do
    test "returns logs for a given execution" do
      {execution, project} = create_execution()
      user_id = execution.user_id

      {:ok, _} =
        SessionLogs.insert(user_id, %{
          project_id: project.id,
          step_execution_id: execution.id,
          content: "Log 1"
        })

      {:ok, _} =
        SessionLogs.insert(user_id, %{
          project_id: project.id,
          step_execution_id: execution.id,
          content: "Log 2"
        })

      logs =
        SessionLogs.all(
          conditions: [step_execution_id: execution.id],
          order_by: [asc: :inserted_at]
        )

      assert length(logs) == 2
      assert Enum.map(logs, & &1.content) == ["Log 1", "Log 2"]
    end

    test "does not return logs from other executions" do
      {execution1, project1} = create_execution()
      {execution2, project2} = create_execution()
      user_id = execution1.user_id

      {:ok, _} =
        SessionLogs.insert(user_id, %{
          project_id: project1.id,
          step_execution_id: execution1.id,
          content: "Log 1"
        })

      {:ok, _} =
        SessionLogs.insert(execution2.user_id, %{
          project_id: project2.id,
          step_execution_id: execution2.id,
          content: "Log 2"
        })

      logs =
        SessionLogs.all(
          conditions: [step_execution_id: execution1.id],
          order_by: [asc: :inserted_at]
        )

      assert length(logs) == 1
      assert hd(logs).content == "Log 1"
    end
  end
end
