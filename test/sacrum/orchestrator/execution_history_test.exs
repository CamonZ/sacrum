defmodule Sacrum.Orchestrator.ExecutionHistoryTest do
  use Sacrum.DataCase

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.ExecutionHistory
  alias Sacrum.Repo

  # ===== Setup helpers =====

  defp create_user do
    {:ok, user} =
      Repo.Users.insert(%{
        email: "execution_history_test@example.com",
        username: "execution_history_test",
        password: "password123"
      })

    user
  end

  defp create_project(user) do
    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "EH Test Project"})
    project
  end

  defp create_workflow(user, project) do
    {:ok, workflow} =
      Accounts.Workflows.insert(user.id, project.id, %{
        name: "Test Workflow",
        auto_advance: false
      })

    workflow
  end

  defp create_step(user, workflow, attrs) do
    default_attrs = %{
      "name" => "Test Step",
      "step_order" => 1,
      "is_final" => false,
      "agents" => ["test"],
      "skills" => ["test_skill"],
      "agent_config" => %{"model" => "test-model"},
      "workflow_id" => workflow.id,
      "project_id" => workflow.project_id,
      "prompt" => "default prompt",
      "output_schema" => nil
    }

    {:ok, step} = Accounts.WorkflowSteps.insert(user.id, Map.merge(default_attrs, attrs))
    step
  end

  defp create_task(user, project, workflow) do
    {:ok, task} =
      Accounts.Tasks.insert(user.id, project.id, %{
        title: "Test Task",
        description: "A test task description",
        level: "ticket",
        tags: ["test"]
      })

    {:ok, task} = Repo.TaskWorkflows.assign_workflow(task, workflow)
    task
  end

  defp create_step_execution(user, task, workflow, step_name, attrs \\ %{}) do
    default_attrs = %{
      "task_id" => task.id,
      "project_id" => task.project_id,
      "workflow_id" => workflow.id,
      "step_name" => step_name,
      "status" => "completed"
    }

    {:ok, execution} =
      Accounts.StepExecutions.insert(user.id, Map.merge(default_attrs, attrs))

    execution
  end

  # ===== Tests =====

  describe "build_execution_data/2" do
    test "builds execution data with previous output and handoff" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step = create_step(user, workflow, %{})
      task = create_task(user, project, workflow)

      # Create a previous completed execution
      _previous =
        create_step_execution(user, task, workflow, step.name, %{
          "status" => "completed",
          "output" => "previous result"
        })

      # Create the current entered execution
      {:ok, entered} =
        Accounts.StepExecutions.insert(user.id, %{
          "task_id" => task.id,
          "project_id" => task.project_id,
          "workflow_id" => workflow.id,
          "step_name" => step.name,
          "status" => "entered",
          "handoff" => %{"key" => "value"}
        })

      data = ExecutionHistory.build_execution_data(task.id, entered)

      assert is_map(data)
      assert data[:previous][:output] == "previous result"
      assert data[:handoff] == %{"key" => "value"}
      assert data[:run_count] == 1
      assert data[:completed_count] == 1
      assert data[:failed_count] == 0
    end

    test "includes run counts in execution data" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step = create_step(user, workflow, %{})
      task = create_task(user, project, workflow)

      # Create completed and failed executions
      _completed1 =
        create_step_execution(user, task, workflow, step.name, %{
          "status" => "completed"
        })

      _completed2 =
        create_step_execution(user, task, workflow, step.name, %{
          "status" => "completed"
        })

      _failed =
        create_step_execution(user, task, workflow, step.name, %{
          "status" => "failed"
        })

      {:ok, entered} =
        Accounts.StepExecutions.insert(user.id, %{
          "task_id" => task.id,
          "project_id" => task.project_id,
          "workflow_id" => workflow.id,
          "step_name" => step.name,
          "status" => "entered"
        })

      data = ExecutionHistory.build_execution_data(task.id, entered)

      assert data[:completed_count] == 2
      assert data[:failed_count] == 1
      assert data[:run_count] == 3
    end
  end

  describe "put_previous_output/2" do
    test "adds previous output from most recent completed execution" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step = create_step(user, workflow, %{})
      task = create_task(user, project, workflow)

      _older =
        create_step_execution(user, task, workflow, step.name, %{
          "status" => "completed",
          "output" => "old output"
        })

      _newer =
        create_step_execution(user, task, workflow, step.name, %{
          "status" => "completed",
          "output" => "new output"
        })

      data = ExecutionHistory.put_previous_output(%{}, task.id)

      assert data[:previous][:output] == "new output"
    end

    test "returns data unchanged if no previous execution" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step = create_step(user, workflow, %{})
      task = create_task(user, project, workflow)

      data = ExecutionHistory.put_previous_output(%{}, task.id)

      assert data == %{}
    end
  end

  describe "decode_prior_output/2" do
    test "decodes JSON output when schema is present" do
      output = "{\"key\": \"value\"}"
      schema = %{"type" => "object"}

      result = ExecutionHistory.decode_prior_output(output, schema)

      assert result == %{"key" => "value"}
    end

    test "returns raw output when schema is nil" do
      output = "plain text output"
      result = ExecutionHistory.decode_prior_output(output, nil)

      assert result == "plain text output"
    end

    test "returns raw output on decode failure" do
      invalid_json = "{invalid json"
      schema = %{"type" => "object"}

      result = ExecutionHistory.decode_prior_output(invalid_json, schema)

      assert result == invalid_json
    end

    test "handles non-binary output" do
      output = 123
      result = ExecutionHistory.decode_prior_output(output, nil)

      assert result == 123
    end
  end

  describe "put_handoff/2" do
    test "adds handoff when it is a map" do
      handoff = %{"key" => "value"}
      data = ExecutionHistory.put_handoff(%{}, handoff)

      assert data[:handoff] == handoff
    end

    test "does not add handoff when it is nil" do
      data = ExecutionHistory.put_handoff(%{}, nil)

      assert data == %{}
    end

    test "does not add handoff when it is not a map" do
      data = ExecutionHistory.put_handoff(%{}, "not a map")

      assert data == %{}
    end
  end

  describe "put_run_counts/3" do
    test "counts completed and failed executions" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step = create_step(user, workflow, %{})
      task = create_task(user, project, workflow)

      create_step_execution(user, task, workflow, step.name, %{"status" => "completed"})
      create_step_execution(user, task, workflow, step.name, %{"status" => "completed"})
      create_step_execution(user, task, workflow, step.name, %{"status" => "failed"})

      data = ExecutionHistory.put_run_counts(%{}, task.id, step.name)

      assert data[:completed_count] == 2
      assert data[:failed_count] == 1
      assert data[:run_count] == 3
    end

    test "returns zeros for new step with no executions" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      _step = create_step(user, workflow, %{})
      task = create_task(user, project, workflow)

      data = ExecutionHistory.put_run_counts(%{}, task.id, "nonexistent_step")

      assert data[:completed_count] == 0
      assert data[:failed_count] == 0
      assert data[:run_count] == 0
    end

    test "ignores non-terminal status executions" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step = create_step(user, workflow, %{})
      task = create_task(user, project, workflow)

      create_step_execution(user, task, workflow, step.name, %{"status" => "entered"})
      create_step_execution(user, task, workflow, step.name, %{"status" => "dispatched"})

      data = ExecutionHistory.put_run_counts(%{}, task.id, step.name)

      assert data[:run_count] == 0
    end
  end
end
