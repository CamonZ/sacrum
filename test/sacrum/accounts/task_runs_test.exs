defmodule Sacrum.Accounts.TaskRunsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.Projects
  alias Sacrum.Accounts.SessionLogs
  alias Sacrum.Accounts.StepExecutions
  alias Sacrum.Accounts.TaskRuns
  alias Sacrum.Accounts.Tasks
  alias Sacrum.Accounts.Workflows
  alias Sacrum.Orchestrator.Routing.WaitChildren.ChildRuns
  alias Sacrum.Orchestrator.TaskRuns.{Failure, RetryExhaustion, Root}
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.StepExecution
  alias Sacrum.Repo.Schemas.TaskRun
  alias Sacrum.Repo.Users
  alias Sacrum.TaskRuns.Status, as: TaskRunStatus

  defp create_user do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Users.insert(%{
        email: "task-runs-#{suffix}@example.com",
        username: "taskruns#{suffix}",
        password: "password123"
      })

    user
  end

  defp create_task_with_workflow(user) do
    {:ok, project} = Projects.insert(user.id, %{name: "TaskRun Project"})
    {:ok, workflow} = Workflows.insert(user.id, project.id, %{name: "TaskRun Workflow"})
    {:ok, task} = Tasks.insert(user.id, project.id, %{title: "TaskRun Task"})

    {project, task, workflow}
  end

  describe "TaskRun status contract" do
    test "defines canonical lifecycle statuses" do
      assert TaskRunStatus.values() == [
               :queued,
               :executing,
               :waiting,
               :stopping,
               :stopped,
               :completed,
               :failed
             ]

      assert TaskRun.statuses() == TaskRunStatus.values()
    end

    test "classifies active, terminal, successful, failed, and stoppable statuses" do
      for status <- [:queued, :executing, :waiting, :stopping] do
        assert TaskRunStatus.active?(status)
        refute TaskRunStatus.terminal?(status)
        refute TaskRunStatus.successful?(status)
        refute TaskRunStatus.failed?(status)
      end

      for status <- [:queued, :executing, :waiting] do
        assert TaskRunStatus.stoppable?(status)
      end

      refute TaskRunStatus.stoppable?(:stopping)

      for status <- [:stopped, :completed, :failed] do
        assert TaskRunStatus.terminal?(status)
        refute TaskRunStatus.active?(status)
        refute TaskRunStatus.stoppable?(status)
      end

      assert TaskRunStatus.successful?(:completed)
      refute TaskRunStatus.successful?(:stopped)
      refute TaskRunStatus.successful?(:failed)

      assert TaskRunStatus.failed?(:failed)
      refute TaskRunStatus.failed?(:stopped)
      refute TaskRunStatus.failed?(:completed)
    end
  end

  describe "TaskRun changesets" do
    test "validate required ownership and status fields" do
      changeset = TaskRun.create_changeset(%TaskRun{}, %{})

      assert %{
               task_id: ["can't be blank"],
               project_id: ["can't be blank"],
               user_id: ["can't be blank"]
             } = errors_on(changeset)

      assert get_field(changeset, :status) == :executing
      assert get_change(changeset, :started_at)
    end

    test "accepts canonical lifecycle statuses" do
      task_run = %TaskRun{
        task_id: Ecto.UUID.generate(),
        project_id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate()
      }

      for status <- TaskRunStatus.values() do
        changeset = TaskRun.create_changeset(task_run, %{status: status})

        assert changeset.valid?, "expected #{inspect(status)} to be valid"
        assert get_field(changeset, :status) == status
      end
    end

    test "rejects statuses outside the TaskRun contract" do
      task_run = %TaskRun{
        task_id: Ecto.UUID.generate(),
        project_id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate()
      }

      for status <- [:cancelled, "entered"] do
        changeset = TaskRun.create_changeset(task_run, %{status: status})

        assert %{status: ["is invalid"]} = errors_on(changeset)
      end
    end
  end

  describe "insert/4" do
    test "creates a task run scoped to user, project, and task" do
      user = create_user()
      {project, task, _workflow} = create_task_with_workflow(user)

      assert {:ok, %TaskRun{} = task_run} = TaskRuns.insert(user.id, project.id, task.id)

      assert task_run.user_id == user.id
      assert task_run.project_id == project.id
      assert task_run.task_id == task.id
      assert task_run.status == :executing
      assert %DateTime{} = task_run.started_at
    end
  end

  describe "get_active_for_task/2" do
    test "returns the latest active run scoped to the user using the status contract" do
      user = create_user()
      {project, task, _workflow} = create_task_with_workflow(user)
      {:ok, _completed} = TaskRuns.insert(user.id, project.id, task.id, %{status: :completed})
      {:ok, _queued} = TaskRuns.insert(user.id, project.id, task.id, %{status: :queued})
      {:ok, _executing} = TaskRuns.insert(user.id, project.id, task.id, %{status: :executing})
      {:ok, _waiting} = TaskRuns.insert(user.id, project.id, task.id, %{status: :waiting})
      {:ok, active} = TaskRuns.insert(user.id, project.id, task.id, %{status: :stopping})
      {:ok, _stopped} = TaskRuns.insert(user.id, project.id, task.id, %{status: :stopped})

      other_user = create_user()

      assert {:ok, found} = TaskRuns.get_active_for_task(user.id, task.id)
      assert found.id == active.id

      assert {:error, :not_found} = TaskRuns.get_active_for_task(other_user.id, task.id)
    end
  end

  describe "list_for_trace/2" do
    test "lists root and descendant runs scoped to the user in deterministic order" do
      user = create_user()
      {project, task, _workflow} = create_task_with_workflow(user)
      {:ok, root} = TaskRuns.insert(user.id, project.id, task.id)

      {:ok, child} =
        TaskRuns.insert(user.id, project.id, task.id, %{
          parent_task_run_id: root.id,
          root_task_run_id: root.id
        })

      {:ok, grandchild} =
        TaskRuns.insert(user.id, project.id, task.id, %{
          parent_task_run_id: child.id,
          root_task_run_id: root.id
        })

      other_user = create_user()
      {other_project, other_task, _workflow} = create_task_with_workflow(other_user)

      {:ok, other_root} = TaskRuns.insert(other_user.id, other_project.id, other_task.id)

      {:ok, out_of_scope} =
        TaskRuns.insert(other_user.id, other_project.id, other_task.id, %{
          parent_task_run_id: other_root.id,
          root_task_run_id: other_root.id
        })

      listed_ids = Enum.map(TaskRuns.list_for_trace(user.id, root.id), & &1.id)
      descendant_ids = Enum.map(TaskRuns.list_descendants_for_trace(user.id, root.id), & &1.id)

      assert listed_ids == [root.id, child.id, grandchild.id]
      assert descendant_ids == [child.id, grandchild.id]
      refute out_of_scope.id in listed_ids
      refute out_of_scope.id in descendant_ids
    end

    test "lists trace executions and session logs through task run joins" do
      user = create_user()
      {project, task, workflow} = create_task_with_workflow(user)
      {:ok, root} = TaskRuns.insert(user.id, project.id, task.id)

      {:ok, child} =
        TaskRuns.insert(user.id, project.id, task.id, %{
          parent_task_run_id: root.id,
          root_task_run_id: root.id
        })

      {:ok, root_execution} =
        StepExecutions.insert(user.id, %{
          "task_id" => task.id,
          "task_run_id" => root.id,
          "project_id" => project.id,
          "workflow_id" => workflow.id,
          "step_name" => "root_step",
          "status" => "completed"
        })

      {:ok, child_execution} =
        StepExecutions.insert(user.id, %{
          "task_id" => task.id,
          "task_run_id" => child.id,
          "project_id" => project.id,
          "workflow_id" => workflow.id,
          "step_name" => "child_step",
          "status" => "completed"
        })

      other_user = create_user()

      {:ok, mismatched_owner_execution} =
        StepExecutions.insert(other_user.id, %{
          "task_id" => task.id,
          "task_run_id" => child.id,
          "project_id" => project.id,
          "workflow_id" => workflow.id,
          "step_name" => "mismatched_owner_step",
          "status" => "completed"
        })

      {:ok, root_log} =
        SessionLogs.insert(user.id, %{
          "project_id" => project.id,
          "step_execution_id" => root_execution.id,
          "content" => "root output"
        })

      {:ok, child_log} =
        SessionLogs.insert(user.id, %{
          "project_id" => project.id,
          "step_execution_id" => child_execution.id,
          "content" => "child output"
        })

      {:ok, mismatched_owner_log} =
        SessionLogs.insert(other_user.id, %{
          "project_id" => project.id,
          "step_execution_id" => child_execution.id,
          "content" => "mismatched owner output"
        })

      {other_project, other_task, other_workflow} = create_task_with_workflow(other_user)
      {:ok, other_root} = TaskRuns.insert(other_user.id, other_project.id, other_task.id)

      {:ok, other_execution} =
        StepExecutions.insert(other_user.id, %{
          "task_id" => other_task.id,
          "task_run_id" => other_root.id,
          "project_id" => other_project.id,
          "workflow_id" => other_workflow.id,
          "step_name" => "other_step",
          "status" => "completed"
        })

      {:ok, other_log} =
        SessionLogs.insert(other_user.id, %{
          "project_id" => other_project.id,
          "step_execution_id" => other_execution.id,
          "content" => "other output"
        })

      trace_execution_ids =
        user.id
        |> TaskRuns.list_step_executions_for_trace(root.id)
        |> Enum.map(& &1.id)

      trace_log_ids =
        user.id
        |> TaskRuns.list_session_logs_for_trace(root.id)
        |> Enum.map(& &1.id)

      assert trace_execution_ids == [root_execution.id, child_execution.id]
      assert trace_log_ids == [root_log.id, child_log.id]
      refute mismatched_owner_execution.id in trace_execution_ids
      refute mismatched_owner_log.id in trace_log_ids
      refute other_execution.id in trace_execution_ids
      refute other_log.id in trace_log_ids
    end

    test "does not attach an unrelated manual child run to a parent trace" do
      user = create_user()
      {project, parent_task, workflow} = create_task_with_workflow(user)
      {:ok, child_task} = Tasks.insert(user.id, project.id, %{title: "Manual child"})
      {:ok, child_task} = Sacrum.Repo.TaskHierarchy.set_parent(child_task, parent_task)

      {:ok, parent_run} = TaskRuns.insert(user.id, project.id, parent_task.id)
      {:ok, manual_child_run} = Root.get_or_create(child_task)

      {:ok, waiting_execution} =
        StepExecutions.insert(user.id, %{
          "task_id" => parent_task.id,
          "task_run_id" => parent_run.id,
          "project_id" => project.id,
          "workflow_id" => workflow.id,
          "step_name" => "wait_children",
          "status" => "waiting",
          "handoff" => %{"child_ids" => [child_task.id]}
        })

      assert {:error, {:child_task_run_has_manual_root, manual_child_run_id}} =
               ChildRuns.get_or_create(
                 child_task,
                 parent_run,
                 waiting_execution.id
               )

      assert manual_child_run_id == manual_child_run.id

      reloaded_manual_run = Repo.get!(TaskRun, manual_child_run.id)
      assert reloaded_manual_run.parent_task_run_id == nil
      assert reloaded_manual_run.root_task_run_id == nil
      assert reloaded_manual_run.triggered_by_step_execution_id == nil

      trace_ids = Enum.map(TaskRuns.list_for_trace(user.id, parent_run.id), & &1.id)
      assert trace_ids == [parent_run.id]
      refute manual_child_run.id in trace_ids
    end

    test "rejects an active child run with a stale triggering execution" do
      user = create_user()
      {project, parent_task, workflow} = create_task_with_workflow(user)
      {:ok, child_task} = Tasks.insert(user.id, project.id, %{title: "Child with stale trigger"})
      {:ok, _child_task} = Sacrum.Repo.TaskHierarchy.set_parent(child_task, parent_task)

      {:ok, parent_run} = TaskRuns.insert(user.id, project.id, parent_task.id)

      {:ok, old_waiting_execution} =
        StepExecutions.insert(user.id, %{
          "task_id" => parent_task.id,
          "task_run_id" => parent_run.id,
          "project_id" => project.id,
          "workflow_id" => workflow.id,
          "step_name" => "wait_children",
          "status" => "waiting"
        })

      {:ok, current_waiting_execution} =
        StepExecutions.insert(user.id, %{
          "task_id" => parent_task.id,
          "task_run_id" => parent_run.id,
          "project_id" => project.id,
          "workflow_id" => workflow.id,
          "step_name" => "wait_children",
          "status" => "waiting"
        })

      {:ok, stale_child_run} =
        TaskRuns.insert(user.id, project.id, child_task.id, %{
          status: :queued,
          parent_task_run_id: parent_run.id,
          root_task_run_id: parent_run.id,
          triggered_by_step_execution_id: old_waiting_execution.id
        })

      assert {:error, {:child_task_run_lineage_conflict, stale_child_run_id}} =
               ChildRuns.get_or_create(
                 child_task,
                 parent_run,
                 current_waiting_execution.id
               )

      assert stale_child_run_id == stale_child_run.id
    end
  end

  describe "step execution association" do
    test "retry exhausted changeset stores retry metadata and latest execution id" do
      task_run = task_run_struct()
      execution = failed_execution_struct(task_run, %{output: nil})

      changed =
        task_run
        |> RetryExhaustion.changeset(execution, %{
          failed_execution_id: execution.id,
          task_id: task_run.task_id,
          current_step_id: execution.step_id,
          current_attempt: 5,
          max_attempts: 5
        })
        |> Ecto.Changeset.apply_changes()

      assert changed.status == :failed
      assert changed.outcome_kind == "retry_exhausted"
      assert changed.latest_step_execution_id == execution.id
      assert changed.outcome_context["failed_execution_id"] == execution.id
      assert changed.outcome_context["task_id"] == task_run.task_id
      assert changed.outcome_context["current_step_id"] == execution.step_id
      assert changed.outcome_context["current_attempt"] == 5
      assert changed.outcome_context["max_attempts"] == 5
      assert changed.outcome_context["execution_found"]
      refute Map.has_key?(changed.outcome_context, "output_preview")
      refute Map.has_key?(changed.outcome_context, "logs")
    end

    test "retry exhausted changeset does not duplicate execution output" do
      task_run = task_run_struct()
      long_output = String.duplicate("daemon error ", 400)
      execution = failed_execution_struct(task_run, %{output: long_output})

      changed =
        task_run
        |> RetryExhaustion.changeset(execution, %{
          failed_execution_id: execution.id,
          current_attempt: 5,
          max_attempts: 5
        })
        |> Ecto.Changeset.apply_changes()

      assert changed.outcome_kind == "retry_exhausted"
      assert changed.latest_step_execution_id == execution.id
      assert changed.outcome_context["failed_execution_id"] == execution.id
      refute Map.has_key?(changed.outcome_context, "output_preview")
      refute Map.has_key?(changed.outcome_context, "output_format")
      refute Map.has_key?(changed.outcome_context, "logs")
    end

    test "retry exhausted changeset handles missing execution rows" do
      task_run = task_run_struct()
      missing_execution_id = Ecto.UUID.generate()

      changed =
        task_run
        |> RetryExhaustion.changeset(nil, %{
          failed_execution_id: missing_execution_id,
          current_attempt: 5,
          max_attempts: 5
        })
        |> Ecto.Changeset.apply_changes()

      assert changed.status == :failed
      assert changed.latest_step_execution_id == nil
      assert changed.outcome_kind == "retry_exhausted"
      assert changed.outcome_context["failed_execution_id"] == missing_execution_id
      assert changed.outcome_context["current_attempt"] == 5
      assert changed.outcome_context["max_attempts"] == 5
      assert changed.outcome_context["execution_found"] == false
      refute Map.has_key?(changed.outcome_context, "output_preview")
      refute Map.has_key?(changed.outcome_context, "logs")
    end

    test "mark_retry_exhausted records retry outcome without copying trace details" do
      user = create_user()
      {project, task, workflow} = create_task_with_workflow(user)
      {:ok, task_run} = TaskRuns.insert(user.id, project.id, task.id)

      {:ok, failed_attempt} =
        StepExecutions.insert(user.id, %{
          "task_id" => task.id,
          "task_run_id" => task_run.id,
          "project_id" => project.id,
          "workflow_id" => workflow.id,
          "step_name" => "retryable_step",
          "status" => "failed",
          "output" => ~S({"error":"daemon timeout"})
        })

      assert {:ok, exhausted} =
               RetryExhaustion.mark(task_run, failed_attempt.id, %{
                 task_id: task.id,
                 current_step_id: failed_attempt.step_id,
                 current_attempt: 5,
                 max_attempts: 5
               })

      assert exhausted.status == :failed
      assert exhausted.latest_step_execution_id == failed_attempt.id
      assert exhausted.outcome_kind == "retry_exhausted"
      assert exhausted.outcome_context["failed_execution_id"] == failed_attempt.id
      assert exhausted.outcome_context["current_step_id"] == failed_attempt.step_id
      assert exhausted.outcome_context["execution_found"]
      refute Map.has_key?(exhausted.outcome_context, "output_preview")
      refute Map.has_key?(exhausted.outcome_context, "logs")
    end

    test "mark_retry_exhausted does not attach an execution from a different task run" do
      user = create_user()
      {project, task, workflow} = create_task_with_workflow(user)
      {:ok, task_run} = TaskRuns.insert(user.id, project.id, task.id)
      {:ok, other_task_run} = TaskRuns.insert(user.id, project.id, task.id)

      {:ok, other_run_attempt} =
        StepExecutions.insert(user.id, %{
          "task_id" => task.id,
          "task_run_id" => other_task_run.id,
          "project_id" => project.id,
          "workflow_id" => workflow.id,
          "step_name" => "retryable_step",
          "status" => "failed"
        })

      assert {:ok, exhausted} =
               RetryExhaustion.mark(task_run, other_run_attempt.id, %{
                 task_id: task.id,
                 current_step_id: other_run_attempt.step_id,
                 current_attempt: 5,
                 max_attempts: 5
               })

      assert exhausted.status == :failed
      assert exhausted.latest_step_execution_id == nil
      assert exhausted.outcome_kind == "retry_exhausted"
      assert exhausted.outcome_context["failed_execution_id"] == other_run_attempt.id
      assert exhausted.outcome_context["execution_found"] == false
    end

    test "failed step attempt does not make an active retrying TaskRun permanently failed" do
      user = create_user()
      {project, task, workflow} = create_task_with_workflow(user)
      {:ok, task_run} = TaskRuns.insert(user.id, project.id, task.id)

      {:ok, failed_attempt} =
        StepExecutions.insert(user.id, %{
          "task_id" => task.id,
          "task_run_id" => task_run.id,
          "project_id" => project.id,
          "workflow_id" => workflow.id,
          "step_name" => "retryable_step",
          "status" => "failed"
        })

      assert {:ok, retrying_run} =
               TaskRuns.update(task_run, %{
                 status: :executing,
                 latest_step_execution_id: failed_attempt.id
               })

      assert failed_attempt.status == "failed"
      assert retrying_run.latest_step_execution_id == failed_attempt.id
      assert TaskRunStatus.active?(retrying_run.status)
      assert TaskRunStatus.stoppable?(retrying_run.status)
      refute TaskRunStatus.failed?(retrying_run.status)
      refute TaskRunStatus.terminal?(retrying_run.status)

      assert {:ok, found} = TaskRuns.get_active_for_task(user.id, task.id)
      assert found.id == retrying_run.id

      assert {:ok, retry_exhausted_run} =
               TaskRuns.update(retrying_run, %{
                 status: :failed,
                 ended_at: DateTime.utc_now()
               })

      assert retry_exhausted_run.latest_step_execution_id == failed_attempt.id
      assert TaskRunStatus.failed?(retry_exhausted_run.status)
      assert TaskRunStatus.terminal?(retry_exhausted_run.status)
      refute TaskRunStatus.active?(retry_exhausted_run.status)

      assert {:error, :not_found} = TaskRuns.get_active_for_task(user.id, task.id)
    end

    test "stopping TaskRun is not converted to failed by failure cleanup" do
      user = create_user()
      {project, task, _workflow} = create_task_with_workflow(user)

      {:ok, task_run} =
        TaskRuns.insert(user.id, project.id, task.id, %{
          status: :stopping,
          stop_requested_at: DateTime.utc_now()
        })

      assert {:ok, :unchanged} =
               Failure.mark_if_active(task_run, :dispatch_failed)

      reloaded = Repo.get!(TaskRun, task_run.id)
      assert reloaded.status == :stopping
      assert reloaded.outcome_kind == nil
      assert reloaded.outcome_context == %{}
      assert reloaded.ended_at == nil
    end

    test "preserves task_run_id and lists executions for a run" do
      user = create_user()
      {project, task, workflow} = create_task_with_workflow(user)
      {:ok, task_run} = TaskRuns.insert(user.id, project.id, task.id)

      other_user = create_user()
      {other_project, other_task, other_workflow} = create_task_with_workflow(other_user)
      {:ok, other_task_run} = TaskRuns.insert(other_user.id, other_project.id, other_task.id)

      {:ok, execution} =
        StepExecutions.insert(user.id, %{
          "task_id" => task.id,
          "task_run_id" => task_run.id,
          "project_id" => project.id,
          "workflow_id" => workflow.id,
          "step_name" => "run_step",
          "status" => "started"
        })

      {:ok, _out_of_scope} =
        StepExecutions.insert(other_user.id, %{
          "task_id" => other_task.id,
          "task_run_id" => other_task_run.id,
          "project_id" => other_project.id,
          "workflow_id" => other_workflow.id,
          "step_name" => "out_of_scope_step",
          "status" => "started"
        })

      assert execution.task_run_id == task_run.id

      execution = Repo.preload(execution, :task_run)
      assert execution.task_run.id == task_run.id
      assert execution.task_run.task_id == task.id

      assert [%StepExecution{} = listed] = TaskRuns.list_step_executions(user.id, task_run.id)
      assert listed.id == execution.id
      assert listed.task_run_id == task_run.id
    end

    test "latest_step_execution_id tracks active cursor and finished last observed execution" do
      user = create_user()
      {project, task, workflow} = create_task_with_workflow(user)
      {:ok, task_run} = TaskRuns.insert(user.id, project.id, task.id)

      {:ok, first_execution} =
        StepExecutions.insert(user.id, %{
          "task_id" => task.id,
          "task_run_id" => task_run.id,
          "project_id" => project.id,
          "workflow_id" => workflow.id,
          "step_name" => "build",
          "status" => "started"
        })

      assert {:ok, executing_run} =
               TaskRuns.update(task_run, %{latest_step_execution_id: first_execution.id})

      assert executing_run.status == :executing
      assert executing_run.latest_step_execution_id == first_execution.id

      {:ok, waiting_execution} =
        StepExecutions.insert(user.id, %{
          "task_id" => task.id,
          "task_run_id" => task_run.id,
          "project_id" => project.id,
          "workflow_id" => workflow.id,
          "step_name" => "wait_children",
          "status" => "waiting",
          "handoff" => %{"child_ids" => [Ecto.UUID.generate()]}
        })

      assert {:ok, waiting_run} =
               TaskRuns.update(executing_run, %{
                 status: :waiting,
                 latest_step_execution_id: waiting_execution.id
               })

      assert waiting_run.status == :waiting
      assert waiting_run.latest_step_execution_id == waiting_execution.id

      ended_at = DateTime.utc_now()

      assert {:ok, completed_run} =
               TaskRuns.update(waiting_run, %{
                 status: :completed,
                 ended_at: ended_at,
                 latest_step_execution_id: waiting_execution.id
               })

      assert completed_run.status == :completed
      assert completed_run.ended_at == ended_at
      assert completed_run.latest_step_execution_id == waiting_execution.id
    end

    test "completed runs persist user-facing outcomes separately from step handoff" do
      user = create_user()
      {project, task, workflow} = create_task_with_workflow(user)
      {:ok, task_run} = TaskRuns.insert(user.id, project.id, task.id)

      {:ok, execution} =
        StepExecutions.insert(user.id, %{
          "task_id" => task.id,
          "task_run_id" => task_run.id,
          "project_id" => project.id,
          "workflow_id" => workflow.id,
          "step_name" => "open_pr",
          "status" => "completed",
          "handoff" => %{"transition" => "next_step"}
        })

      outcome_context = %{
        "kind" => "pull_request",
        "url" => "https://example.test/pull/123",
        "source_step" => "open_pr"
      }

      assert {:ok, completed_run} =
               TaskRuns.update(task_run, %{
                 status: :completed,
                 ended_at: DateTime.utc_now(),
                 latest_step_execution_id: execution.id,
                 outcome_kind: "pull_request_created",
                 outcome_context: outcome_context
               })

      assert completed_run.status == :completed
      assert completed_run.outcome_kind == "pull_request_created"
      assert completed_run.outcome_context == outcome_context

      persisted_execution = Repo.get!(StepExecution, execution.id)
      assert persisted_execution.handoff == %{"transition" => "next_step"}
    end

    test "keeps historical executions without task_run_id queryable" do
      user = create_user()
      {project, task, workflow} = create_task_with_workflow(user)

      {:ok, execution} =
        StepExecutions.insert(user.id, %{
          "task_id" => task.id,
          "project_id" => project.id,
          "workflow_id" => workflow.id,
          "step_name" => "legacy_step",
          "status" => "completed"
        })

      assert execution.task_run_id == nil
      assert {:ok, found} = StepExecutions.get_by(user.id, conditions: [id: execution.id])
      assert found.id == execution.id
      assert found.task_run_id == nil

      executions = StepExecutions.list_by(user.id, conditions: [task_id: task.id])
      assert Enum.map(executions, & &1.id) == [execution.id]
    end

    test "allows assigning a task_run_id to an existing execution" do
      user = create_user()
      {project, task, workflow} = create_task_with_workflow(user)
      {:ok, task_run} = TaskRuns.insert(user.id, project.id, task.id)

      {:ok, execution} =
        StepExecutions.insert(user.id, %{
          "task_id" => task.id,
          "project_id" => project.id,
          "workflow_id" => workflow.id,
          "step_name" => "backfilled_step",
          "status" => "completed"
        })

      assert execution.task_run_id == nil

      assert {:ok, updated} = StepExecutions.update(execution, %{task_run_id: task_run.id})
      assert updated.task_run_id == task_run.id
    end
  end

  defp task_run_struct(attrs \\ %{}) do
    Map.merge(
      %TaskRun{
        id: Ecto.UUID.generate(),
        task_id: Ecto.UUID.generate(),
        project_id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate(),
        status: :executing
      },
      attrs
    )
  end

  defp failed_execution_struct(task_run, attrs) do
    Map.merge(
      %StepExecution{
        id: Ecto.UUID.generate(),
        task_run_id: task_run.id,
        task_id: task_run.task_id,
        project_id: task_run.project_id,
        step_id: Ecto.UUID.generate(),
        step_name: "retryable_step",
        status: "failed"
      },
      attrs
    )
  end
end
