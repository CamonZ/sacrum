defmodule Sacrum.Repo.SessionLogsTest do
  use Sacrum.DataCase, async: false

  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Workflows
  alias Sacrum.Repo.SessionLogs
  alias Sacrum.Repo.StepExecutions
  alias Sacrum.Repo.Tasks
  alias Sacrum.Repo.Schemas.{SessionLog, StepExecution}

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

    test "upserts logs with the same logical key for an execution" do
      {execution, project} = create_execution()
      user_id = execution.user_id

      assert {:ok, first_log} =
               SessionLogs.insert(user_id, %{
                 project_id: project.id,
                 step_execution_id: execution.id,
                 logical_key: "system/thinking_tokens",
                 content: "first snapshot"
               })

      Process.sleep(2)

      assert {:ok, second_log} =
               SessionLogs.insert(user_id, %{
                 project_id: project.id,
                 step_execution_id: execution.id,
                 logical_key: "system/thinking_tokens",
                 content: "latest snapshot"
               })

      assert second_log.id == first_log.id
      assert second_log.inserted_at == first_log.inserted_at
      assert DateTime.compare(second_log.updated_at, first_log.updated_at) == :gt
      assert second_log.content == "latest snapshot"

      logs =
        SessionLogs.all(
          conditions: [step_execution_id: execution.id],
          order_by: [asc: :inserted_at]
        )

      assert Enum.map(logs, & &1.id) == [first_log.id]
      assert hd(logs).content == "latest snapshot"
      assert hd(logs).logical_key == "system/thinking_tokens"
    end

    test "refreshes rollup totals when a logical-key usage log is updated" do
      {execution, project} = create_execution()
      user_id = execution.user_id

      assert {:ok, first_log} =
               SessionLogs.insert(user_id, %{
                 project_id: project.id,
                 step_execution_id: execution.id,
                 logical_key: "system/thinking_tokens",
                 format: "anthropic",
                 content:
                   anthropic_usage_content(input: 10, cache_create: 5, cache_read: 2, output: 3)
               })

      reloaded = Repo.get!(StepExecution, execution.id)
      assert reloaded.session_input_tokens == 17
      assert reloaded.session_cache_read_input_tokens == 2
      assert reloaded.session_output_tokens == 3
      assert reloaded.session_total_tokens == 20

      assert {:ok, second_log} =
               SessionLogs.insert(user_id, %{
                 project_id: project.id,
                 step_execution_id: execution.id,
                 logical_key: "system/thinking_tokens",
                 format: "anthropic",
                 content:
                   anthropic_usage_content(input: 20, cache_create: 7, cache_read: 4, output: 6)
               })

      assert second_log.id == first_log.id

      reloaded = Repo.get!(StepExecution, execution.id)
      assert reloaded.session_input_tokens == 31
      assert reloaded.session_cache_read_input_tokens == 4
      assert reloaded.session_output_tokens == 6
      assert reloaded.session_total_tokens == 37
      assert reloaded.context_window_input_tokens == 31
      assert reloaded.context_window_cache_read_input_tokens == 4
      assert reloaded.context_window_total_tokens == 37

      assert {:ok, plain_log} =
               SessionLogs.insert(user_id, %{
                 project_id: project.id,
                 step_execution_id: execution.id,
                 logical_key: "system/thinking_tokens",
                 format: "anthropic",
                 content: "latest snapshot without usage"
               })

      assert plain_log.id == first_log.id

      reloaded = Repo.get!(StepExecution, execution.id)
      assert reloaded.session_input_tokens == 0
      assert reloaded.session_cache_read_input_tokens == 0
      assert reloaded.session_output_tokens == 0
      assert reloaded.session_total_tokens == 0
      assert reloaded.context_window_input_tokens == 0
      assert reloaded.context_window_cache_read_input_tokens == 0
      assert reloaded.context_window_total_tokens == 0
    end

    test "appends logs when logical key is nil" do
      {execution, project} = create_execution()
      user_id = execution.user_id

      assert {:ok, first_log} =
               SessionLogs.insert(user_id, %{
                 project_id: project.id,
                 step_execution_id: execution.id,
                 logical_key: nil,
                 content: "plain line 1"
               })

      assert {:ok, second_log} =
               SessionLogs.insert(user_id, %{
                 project_id: project.id,
                 step_execution_id: execution.id,
                 content: "plain line 2"
               })

      assert second_log.id != first_log.id

      logs =
        SessionLogs.all(
          conditions: [step_execution_id: execution.id],
          order_by: [asc: :inserted_at]
        )

      assert Enum.map(logs, fn log -> log.content end) == ["plain line 1", "plain line 2"]
      assert Enum.all?(logs, &is_nil(&1.logical_key))
    end

    test "concurrent upserts with the same logical key leave one row" do
      {execution, project} = create_execution()
      user_id = execution.user_id

      results =
        ["concurrent 1", "concurrent 2"]
        |> Task.async_stream(
          fn content ->
            SessionLogs.insert(user_id, %{
              project_id: project.id,
              step_execution_id: execution.id,
              logical_key: "system/task_progress:toolu_123",
              content: content
            })
          end,
          max_concurrency: 2,
          ordered: false,
          timeout: 10_000
        )
        |> Enum.to_list()

      assert Enum.all?(results, fn
               {:ok, {:ok, %SessionLog{}}} -> true
               _ -> false
             end)

      logs = SessionLogs.all(conditions: [step_execution_id: execution.id])

      assert length(logs) == 1
      assert hd(logs).logical_key == "system/task_progress:toolu_123"
      assert hd(logs).content in ["concurrent 1", "concurrent 2"]
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

  defp anthropic_usage_content(opts) do
    Jason.encode!(%{
      "usage" => %{
        "input_tokens" => Keyword.fetch!(opts, :input),
        "cache_creation_input_tokens" => Keyword.fetch!(opts, :cache_create),
        "cache_read_input_tokens" => Keyword.fetch!(opts, :cache_read),
        "output_tokens" => Keyword.fetch!(opts, :output)
      }
    })
  end
end
