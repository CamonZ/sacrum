defmodule Sacrum.Accounts.SessionLogsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.SessionLogs
  alias Sacrum.Accounts.StepExecutions
  alias Sacrum.Accounts.Workflows
  alias Sacrum.Accounts.Tasks
  alias Sacrum.Accounts.Projects
  alias Sacrum.Repo
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Schemas.{SessionLog, StepExecution}

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
      assert log.format == "anthropic"
    end

    test "accepts only supported session log formats" do
      changeset =
        SessionLog.create_changeset(%SessionLog{}, %{
          "step_execution_id" => Ecto.UUID.generate(),
          "content" => "Session started",
          "format" => "anthropic"
        })

      assert changeset.valid?

      harness_changeset =
        SessionLog.create_changeset(%SessionLog{}, %{
          "step_execution_id" => Ecto.UUID.generate(),
          "content" => "{}",
          "format" => "harness"
        })

      assert harness_changeset.valid?

      changeset =
        SessionLog.create_changeset(%SessionLog{}, %{
          "step_execution_id" => Ecto.UUID.generate(),
          "content" => "Session started",
          "format" => "codex"
        })

      assert %{format: ["is invalid"]} = errors_on(changeset)
    end

    test "rolls up Anthropic usage into the owning step execution" do
      user = create_user()
      {project, execution} = create_step_execution(user)

      assert {:ok, %SessionLog{}} =
               SessionLogs.insert(user.id, %{
                 "step_execution_id" => execution.id,
                 "project_id" => project.id,
                 "format" => "anthropic",
                 "content" =>
                   Jason.encode!(%{
                     "usage" => %{
                       "input_tokens" => 100,
                       "cache_creation_input_tokens" => 20,
                       "cache_read_input_tokens" => 30,
                       "output_tokens" => 40
                     }
                   })
               })

      reloaded = Repo.get!(StepExecution, execution.id)
      assert reloaded.session_input_tokens == 150
      assert reloaded.session_cache_read_input_tokens == 30
      assert reloaded.session_output_tokens == 40
      assert reloaded.session_total_tokens == 190
      assert reloaded.context_window_input_tokens == 150
      assert reloaded.context_window_cache_read_input_tokens == 30
      assert reloaded.context_window_total_tokens == 190
    end

    test "rolls up OpenAI usage without requiring cache creation tokens" do
      user = create_user()
      {project, execution} = create_step_execution(user)

      assert {:ok, %SessionLog{}} =
               SessionLogs.insert(user.id, %{
                 "step_execution_id" => execution.id,
                 "project_id" => project.id,
                 "format" => "openai",
                 "content" =>
                   Jason.encode!(%{
                     "usage" => %{
                       "input_tokens" => 100,
                       "input_token_details" => %{"cached_tokens" => 30},
                       "output_tokens" => 25
                     }
                   })
               })

      reloaded = Repo.get!(StepExecution, execution.id)
      assert reloaded.session_input_tokens == 100
      assert reloaded.session_cache_read_input_tokens == 30
      assert reloaded.session_output_tokens == 25
      assert reloaded.session_total_tokens == 125
      assert reloaded.context_window_input_tokens == 100
      assert reloaded.context_window_cache_read_input_tokens == 30
      assert reloaded.context_window_total_tokens == 125
    end

    test "rolls up Codex cache reads reported as cached_input_tokens" do
      user = create_user()
      {project, execution} = create_step_execution(user)

      # Codex `exec --json` emits cache reads on the turn.completed usage under
      # the `cached_input_tokens` key, distinct from other OpenAI response
      # shapes — the rollup must recognize it or cache reads silently read 0.
      assert {:ok, %SessionLog{}} =
               SessionLogs.insert(user.id, %{
                 "step_execution_id" => execution.id,
                 "project_id" => project.id,
                 "format" => "openai",
                 "content" =>
                   Jason.encode!(%{
                     "type" => "turn.completed",
                     "usage" => %{
                       "input_tokens" => 1500,
                       "cached_input_tokens" => 200,
                       "output_tokens" => 800,
                       "reasoning_output_tokens" => 120
                     }
                   })
               })

      reloaded = Repo.get!(StepExecution, execution.id)
      assert reloaded.session_input_tokens == 1500
      assert reloaded.session_cache_read_input_tokens == 200
      assert reloaded.session_output_tokens == 800
      assert reloaded.context_window_cache_read_input_tokens == 200
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
