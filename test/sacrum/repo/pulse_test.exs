defmodule Sacrum.Repo.PulseTest do
  use Sacrum.DataCase

  alias Sacrum.Repo
  alias Sacrum.Repo.Pulse

  defp create_user(
         attrs \\ %{email: "test@example.com", username: "testuser", password: "password123"}
       ) do
    {:ok, user} = Repo.Users.insert(attrs)
    user
  end

  defp create_project(user, attrs \\ %{name: "Test Project"}) do
    {:ok, project} = Repo.Projects.insert(user, attrs)
    project
  end

  defp create_workflow(user, project, attrs \\ %{name: "Test Workflow"}) do
    {:ok, workflow} =
      Repo.Workflows.insert(project, %{
        name: Map.get(attrs, :name, "Test Workflow"),
        user_id: user.id
      })

    workflow
  end

  defp create_workflow_step(user, workflow, attrs \\ %{name: "Step 1", is_final: false}) do
    {:ok, step} =
      Repo.WorkflowSteps.insert(workflow, %{
        name: Map.get(attrs, :name, "Step 1"),
        is_final: Map.get(attrs, :is_final, false)
      })

    step
  end

  defp create_task(user, project, attrs \\ %{title: "Test Task"}) do
    {:ok, task} =
      Repo.Tasks.insert(project, %{
        title: Map.get(attrs, :title, "Test Task")
      })

    task
  end

  defp create_step_execution(user, attrs) do
    {:ok, execution} =
      Repo.StepExecutions.insert(user.id, attrs)

    # If inserted_at was passed in, backdate the record
    if inserted_at = Map.get(attrs, :inserted_at) do
      updated =
        execution
        |> Ecto.Changeset.change(inserted_at: inserted_at)
        |> Repo.update!()

      updated
    else
      execution
    end
  end

  # Tests

  describe "concurrency" do
    alias Sacrum.Orchestrator.ExecutionPool

    test "matches the live ExecutionPool state" do
      {:ok, slot} = ExecutionPool.request_slot(self())

      try do
        %{in_use_count: in_use, max_concurrent: cap} = ExecutionPool.pool_status()
        assert Pulse.get_concurrency_and_cap() == {in_use, cap}
        assert in_use >= 1
      after
        ExecutionPool.release_slot(slot)
      end
    end
  end

  describe "spend_usd" do
    test "returns 0 when no step executions exist" do
      user = create_user()
      project = create_project(user)
      assert Pulse.get_spend_usd(project.id) == Decimal.new(0)
    end

    test "sums cost from step executions in the past 24 hours" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step = create_workflow_step(user, workflow)
      task = create_task(user, project)

      # Create executions with costs
      _ex1 =
        create_step_execution(user, %{
          task_id: task.id,
          step_name: "Step 1",
          workflow_id: workflow.id,
          step_id: step.id,
          project_id: project.id,
          cost: Decimal.new("1.50"),
          inserted_at: DateTime.utc_now()
        })

      _ex2 =
        create_step_execution(user, %{
          task_id: task.id,
          step_name: "Step 2",
          workflow_id: workflow.id,
          step_id: step.id,
          project_id: project.id,
          cost: Decimal.new("2.25"),
          inserted_at: DateTime.utc_now()
        })

      spend = Pulse.get_spend_usd(project.id)
      assert Decimal.equal?(spend, Decimal.new("3.75"))
    end

    test "ignores step executions outside 24-hour window" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step = create_workflow_step(user, workflow)

      # Old task - from 25+ hours ago
      old_task = create_task(user, project, %{title: "Old Task"})
      old_time = DateTime.utc_now() |> DateTime.add(-100_000, :second)

      _ex_old =
        create_step_execution(user, %{
          task_id: old_task.id,
          step_name: "Step 1",
          workflow_id: workflow.id,
          step_id: step.id,
          project_id: project.id,
          cost: Decimal.new("10.00"),
          inserted_at: old_time
        })

      # Recent task - within 24 hours
      recent_task = create_task(user, project, %{title: "Recent Task"})

      _ex_new =
        create_step_execution(user, %{
          task_id: recent_task.id,
          step_name: "Step 2",
          workflow_id: workflow.id,
          step_id: step.id,
          project_id: project.id,
          cost: Decimal.new("1.00"),
          inserted_at: DateTime.utc_now()
        })

      spend = Pulse.get_spend_usd(project.id)
      assert Decimal.equal?(spend, Decimal.new("1.00"))
    end

    test "ignores executions with null cost" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step = create_workflow_step(user, workflow)
      task = create_task(user, project)

      _ex_no_cost =
        create_step_execution(user, %{
          task_id: task.id,
          step_name: "Step 1",
          workflow_id: workflow.id,
          step_id: step.id,
          project_id: project.id,
          cost: nil,
          inserted_at: DateTime.utc_now()
        })

      spend = Pulse.get_spend_usd(project.id)
      assert Decimal.equal?(spend, Decimal.new(0))
    end
  end

  describe "spend_tokens" do
    test "returns 0 when no step executions exist" do
      user = create_user()
      project = create_project(user)
      assert Pulse.get_spend_tokens(project.id) == 0
    end

    test "sums input and output tokens from step executions in the past 24 hours" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step = create_workflow_step(user, workflow)
      task = create_task(user, project)

      _ex1 =
        create_step_execution(user, %{
          task_id: task.id,
          step_name: "Step 1",
          workflow_id: workflow.id,
          step_id: step.id,
          project_id: project.id,
          input_tokens: 1000,
          output_tokens: 500,
          inserted_at: DateTime.utc_now()
        })

      _ex2 =
        create_step_execution(user, %{
          task_id: task.id,
          step_name: "Step 2",
          workflow_id: workflow.id,
          step_id: step.id,
          project_id: project.id,
          input_tokens: 2000,
          output_tokens: 1000,
          inserted_at: DateTime.utc_now()
        })

      tokens = Pulse.get_spend_tokens(project.id)
      assert tokens == 4500
    end

    test "ignores executions outside 24-hour window" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step = create_workflow_step(user, workflow)

      old_task = create_task(user, project, %{title: "Old Task"})
      old_time = DateTime.utc_now() |> DateTime.add(-100_000, :second)

      _ex_old =
        create_step_execution(user, %{
          task_id: old_task.id,
          step_name: "Step 1",
          workflow_id: workflow.id,
          step_id: step.id,
          project_id: project.id,
          input_tokens: 10000,
          output_tokens: 5000,
          inserted_at: old_time
        })

      recent_task = create_task(user, project, %{title: "Recent Task"})

      _ex_new =
        create_step_execution(user, %{
          task_id: recent_task.id,
          step_name: "Step 2",
          workflow_id: workflow.id,
          step_id: step.id,
          project_id: project.id,
          input_tokens: 100,
          output_tokens: 50,
          inserted_at: DateTime.utc_now()
        })

      tokens = Pulse.get_spend_tokens(project.id)
      assert tokens == 150
    end
  end

  describe "throughput" do
    test "returns 0 when no tasks are completed" do
      user = create_user()
      project = create_project(user)
      assert Pulse.get_throughput(project.id) == 0
    end

    test "counts distinct tasks that completed a final step in the past 24 hours" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step_normal = create_workflow_step(user, workflow, %{is_final: false})
      step_final = create_workflow_step(user, workflow, %{is_final: true})

      task1 = create_task(user, project, %{title: "Task 1"})
      task2 = create_task(user, project, %{title: "Task 2"})
      task3 = create_task(user, project, %{title: "Task 3"})

      # Task 1: completed to final step = counted
      _ex1 =
        create_step_execution(user, %{
          task_id: task1.id,
          step_name: "Final",
          workflow_id: workflow.id,
          step_id: step_final.id,
          project_id: project.id,
          status: "completed",
          inserted_at: DateTime.utc_now()
        })

      # Task 2: completed to final step = counted (even with multiple executions)
      _ex2a =
        create_step_execution(user, %{
          task_id: task2.id,
          step_name: "Normal",
          workflow_id: workflow.id,
          step_id: step_normal.id,
          project_id: project.id,
          status: "completed",
          inserted_at: DateTime.utc_now() |> DateTime.add(-1000, :second)
        })

      _ex2b =
        create_step_execution(user, %{
          task_id: task2.id,
          step_name: "Final",
          workflow_id: workflow.id,
          step_id: step_final.id,
          project_id: project.id,
          status: "completed",
          inserted_at: DateTime.utc_now()
        })

      # Task 3: execution not completed = not counted
      _ex3 =
        create_step_execution(user, %{
          task_id: task3.id,
          step_name: "Final",
          workflow_id: workflow.id,
          step_id: step_final.id,
          project_id: project.id,
          status: "running",
          inserted_at: DateTime.utc_now()
        })

      throughput = Pulse.get_throughput(project.id)
      assert throughput == 2
    end

    test "ignores executions outside 24-hour window" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step_final = create_workflow_step(user, workflow, %{is_final: true})
      step_normal = create_workflow_step(user, workflow, %{is_final: false})

      old_task = create_task(user, project, %{title: "Old Task"})
      old_time = DateTime.utc_now() |> DateTime.add(-100_000, :second)

      # Execution outside 24h window
      _ex_old =
        create_step_execution(user, %{
          task_id: old_task.id,
          step_name: "Normal",
          workflow_id: workflow.id,
          step_id: step_normal.id,
          project_id: project.id,
          status: "completed",
          inserted_at: old_time
        })

      _ex_old_final =
        create_step_execution(user, %{
          task_id: old_task.id,
          step_name: "Final",
          workflow_id: workflow.id,
          step_id: step_final.id,
          project_id: project.id,
          status: "completed",
          inserted_at: old_time |> DateTime.add(1000, :millisecond)
        })

      throughput = Pulse.get_throughput(project.id)
      assert throughput == 0
    end
  end

  describe "p50_duration_ms" do
    test "returns 0 when no tasks are completed" do
      user = create_user()
      project = create_project(user)
      assert Pulse.get_p50_duration_ms(project.id) == 0
    end

    test "calculates median time-to-terminal-step for completed tasks" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step_final = create_workflow_step(user, workflow, %{is_final: true})
      step_normal = create_workflow_step(user, workflow, %{is_final: false})

      # Task 1: 1000ms duration
      task1 = create_task(user, project, %{title: "Task 1"})
      t1_start = DateTime.utc_now() |> DateTime.add(-1500, :millisecond)

      _ex1a =
        create_step_execution(user, %{
          task_id: task1.id,
          step_name: "Start",
          workflow_id: workflow.id,
          step_id: step_normal.id,
          project_id: project.id,
          status: "completed",
          inserted_at: t1_start
        })

      _ex1b =
        create_step_execution(user, %{
          task_id: task1.id,
          step_name: "Final",
          workflow_id: workflow.id,
          step_id: step_final.id,
          project_id: project.id,
          status: "completed",
          inserted_at: t1_start |> DateTime.add(1000, :millisecond)
        })

      # Task 2: 2000ms duration
      task2 = create_task(user, project, %{title: "Task 2"})
      t2_start = DateTime.utc_now() |> DateTime.add(-3000, :millisecond)

      _ex2a =
        create_step_execution(user, %{
          task_id: task2.id,
          step_name: "Start",
          workflow_id: workflow.id,
          step_id: step_normal.id,
          project_id: project.id,
          status: "completed",
          inserted_at: t2_start
        })

      _ex2b =
        create_step_execution(user, %{
          task_id: task2.id,
          step_name: "Final",
          workflow_id: workflow.id,
          step_id: step_final.id,
          project_id: project.id,
          status: "completed",
          inserted_at: t2_start |> DateTime.add(2000, :millisecond)
        })

      # Task 3: 3000ms duration
      task3 = create_task(user, project, %{title: "Task 3"})
      t3_start = DateTime.utc_now() |> DateTime.add(-4500, :millisecond)

      _ex3a =
        create_step_execution(user, %{
          task_id: task3.id,
          step_name: "Start",
          workflow_id: workflow.id,
          step_id: step_normal.id,
          project_id: project.id,
          status: "completed",
          inserted_at: t3_start
        })

      _ex3b =
        create_step_execution(user, %{
          task_id: task3.id,
          step_name: "Final",
          workflow_id: workflow.id,
          step_id: step_final.id,
          project_id: project.id,
          status: "completed",
          inserted_at: t3_start |> DateTime.add(3000, :millisecond)
        })

      p50 = Pulse.get_p50_duration_ms(project.id)
      # Sorted: [1000, 2000, 3000], median is 2000
      assert p50 == 2000
    end

    test "ignores executions outside 24-hour window" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step_final = create_workflow_step(user, workflow, %{is_final: true})
      step_normal = create_workflow_step(user, workflow, %{is_final: false})

      task = create_task(user, project)

      old_time = DateTime.utc_now() |> DateTime.add(-100_000, :second)

      _ex_old =
        create_step_execution(user, %{
          task_id: task.id,
          step_name: "Start",
          workflow_id: workflow.id,
          step_id: step_normal.id,
          project_id: project.id,
          status: "completed",
          inserted_at: old_time
        })

      _ex_old_final =
        create_step_execution(user, %{
          task_id: task.id,
          step_name: "Final",
          workflow_id: workflow.id,
          step_id: step_final.id,
          project_id: project.id,
          status: "completed",
          inserted_at: old_time |> DateTime.add(1000, :millisecond)
        })

      p50 = Pulse.get_p50_duration_ms(project.id)
      assert p50 == 0
    end
  end

  describe "get_all_metrics" do
    test "returns all metrics in a single map" do
      user = create_user()
      project = create_project(user)

      metrics = Pulse.get_all_metrics(project.id)

      assert is_map(metrics)
      assert Map.has_key?(metrics, :concurrency)
      assert Map.has_key?(metrics, :cap)
      assert Map.has_key?(metrics, :spend_usd)
      assert Map.has_key?(metrics, :spend_tokens)
      assert Map.has_key?(metrics, :throughput)
      assert Map.has_key?(metrics, :p50_duration_ms)

      assert is_integer(metrics.cap) and metrics.cap > 0
      assert is_integer(metrics.concurrency)
      assert is_struct(metrics.spend_usd, Decimal)
      assert is_integer(metrics.spend_tokens)
      assert is_integer(metrics.throughput)
      assert is_integer(metrics.p50_duration_ms)
    end
  end
end
