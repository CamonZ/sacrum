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

  test "requires identity and rejects provider formats before persistence" do
    {execution, project} = create_execution()

    for attrs <- [
          %{content: Sacrum.HarnessFixture.content("text")},
          Map.put(Sacrum.HarnessFixture.attrs("text"), :format, "anthropic"),
          Map.put(Sacrum.HarnessFixture.attrs("text"), :format, "openai"),
          %{logical_key: "harness:invalid", content: "not json"}
        ] do
      changeset =
        SessionLogs.changeset(
          execution.user_id,
          Map.merge(attrs, %{project_id: project.id, step_execution_id: execution.id})
        )

      refute changeset.valid?
    end

    assert Repo.aggregate(SessionLog, :count) == 0
  end

  test "requires content and execution" do
    {execution, project} = create_execution()

    changeset =
      SessionLogs.changeset(execution.user_id, %{
        project_id: project.id,
        step_execution_id: execution.id
      })

    assert %{content: ["can't be blank"]} = errors_on(changeset)

    changeset =
      SessionLogs.changeset(
        execution.user_id,
        Map.merge(Sacrum.HarnessFixture.attrs("text"), %{project_id: project.id})
      )

    assert %{step_execution_id: ["can't be blank"]} = errors_on(changeset)
  end
end
