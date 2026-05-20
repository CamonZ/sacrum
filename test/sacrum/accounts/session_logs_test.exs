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

  defp anthropic_usage(input, cache_create, cache_read, output) do
    Jason.encode!(%{
      "usage" => %{
        "input_tokens" => input,
        "cache_creation_input_tokens" => cache_create,
        "cache_read_input_tokens" => cache_read,
        "output_tokens" => output
      }
    })
  end

  defp openai_usage(input, cache_read, output) do
    Jason.encode!(%{
      "usage" => %{
        "input_tokens" => input,
        "input_token_details" => %{"cached_tokens" => cache_read},
        "output_tokens" => output
      }
    })
  end

  defp assert_rollup(execution, attrs) do
    reloaded = Repo.get!(StepExecution, execution.id)

    assert reloaded.session_input_tokens == attrs.input
    assert reloaded.session_cache_read_input_tokens == attrs.cache_read
    assert reloaded.session_output_tokens == attrs.output
    assert reloaded.session_total_tokens == attrs.total
    assert reloaded.context_window_input_tokens == attrs.context_input
    assert reloaded.context_window_cache_read_input_tokens == attrs.context_cache_read
    assert reloaded.context_window_total_tokens == attrs.context_total
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

    test "accepts only supported provider formats" do
      changeset =
        SessionLog.create_changeset(%SessionLog{}, %{
          "step_execution_id" => Ecto.UUID.generate(),
          "content" => "Session started",
          "format" => "anthropic"
        })

      assert changeset.valid?

      changeset =
        SessionLog.create_changeset(%SessionLog{}, %{
          "step_execution_id" => Ecto.UUID.generate(),
          "content" => "Session started",
          "format" => "codex"
        })

      assert %{format: ["is invalid"]} = errors_on(changeset)
    end

    test "update changeset changes only content" do
      log = %SessionLog{
        content: "Before",
        format: "anthropic",
        step_execution_id: Ecto.UUID.generate(),
        project_id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate()
      }

      attrs = %{
        "content" => "After",
        "format" => "openai",
        "step_execution_id" => Ecto.UUID.generate(),
        "project_id" => Ecto.UUID.generate(),
        "user_id" => Ecto.UUID.generate()
      }

      changeset = SessionLog.update_changeset(log, attrs)
      assert changeset.valid?
      assert changeset.changes == %{content: "After"}

      updated = Ecto.Changeset.apply_changes(changeset)
      assert updated.content == "After"
      assert updated.format == log.format
      assert updated.step_execution_id == log.step_execution_id
      assert updated.project_id == log.project_id
      assert updated.user_id == log.user_id
    end

    test "rolls up Anthropic usage into the owning step execution" do
      user = create_user()
      {project, execution} = create_step_execution(user)

      assert {:ok, %SessionLog{}} =
               SessionLogs.insert(user.id, %{
                 "step_execution_id" => execution.id,
                 "project_id" => project.id,
                 "format" => "anthropic",
                 "content" => anthropic_usage(100, 20, 30, 40)
               })

      assert_rollup(execution, %{
        input: 150,
        cache_read: 30,
        output: 40,
        total: 190,
        context_input: 150,
        context_cache_read: 30,
        context_total: 190
      })
    end

    test "rolls up OpenAI usage without requiring cache creation tokens" do
      user = create_user()
      {project, execution} = create_step_execution(user)

      assert {:ok, %SessionLog{}} =
               SessionLogs.insert(user.id, %{
                 "step_execution_id" => execution.id,
                 "project_id" => project.id,
                 "format" => "openai",
                 "content" => openai_usage(100, 30, 25)
               })

      assert_rollup(execution, %{
        input: 100,
        cache_read: 30,
        output: 25,
        total: 125,
        context_input: 100,
        context_cache_read: 30,
        context_total: 125
      })
    end
  end

  describe "update/2" do
    test "updates content and recomputes Anthropic rollups without double counting" do
      user = create_user()
      {project, execution} = create_step_execution(user)

      {:ok, log} =
        SessionLogs.insert(user.id, %{
          "step_execution_id" => execution.id,
          "project_id" => project.id,
          "format" => "anthropic",
          "content" => anthropic_usage(100, 20, 30, 40)
        })

      assert {:ok, updated} =
               SessionLogs.update(log, %{
                 "content" => anthropic_usage(10, 2, 3, 4)
               })

      assert updated.id == log.id
      assert updated.format == "anthropic"
      assert updated.content != log.content

      assert_rollup(execution, %{
        input: 15,
        cache_read: 3,
        output: 4,
        total: 19,
        context_input: 15,
        context_cache_read: 3,
        context_total: 19
      })
    end

    test "updates content and recomputes OpenAI rollups without double counting" do
      user = create_user()
      {project, execution} = create_step_execution(user)

      {:ok, log} =
        SessionLogs.insert(user.id, %{
          "step_execution_id" => execution.id,
          "project_id" => project.id,
          "format" => "openai",
          "content" => openai_usage(100, 30, 25)
        })

      assert {:ok, updated} =
               SessionLogs.update(log, %{
                 "content" => openai_usage(20, 5, 8)
               })

      assert updated.id == log.id
      assert updated.format == "openai"

      assert_rollup(execution, %{
        input: 20,
        cache_read: 5,
        output: 8,
        total: 28,
        context_input: 20,
        context_cache_read: 5,
        context_total: 28
      })
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
