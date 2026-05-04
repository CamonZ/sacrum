defmodule Sacrum.Accounts.TaskRunsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.Projects
  alias Sacrum.Accounts.StepExecutions
  alias Sacrum.Accounts.TaskRuns
  alias Sacrum.Accounts.Tasks
  alias Sacrum.Accounts.Workflows
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.StepExecution
  alias Sacrum.Repo.Schemas.TaskRun
  alias Sacrum.Repo.Users

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

    test "accepts intended lifecycle statuses including waiting" do
      task_run = %TaskRun{
        task_id: Ecto.UUID.generate(),
        project_id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate()
      }

      for status <- [:executing, :waiting, :stopping, :completed, :failed, :cancelled] do
        changeset = TaskRun.create_changeset(task_run, %{status: status})

        assert changeset.valid?, "expected #{inspect(status)} to be valid"
        assert get_field(changeset, :status) == status
      end
    end

    test "reject invalid statuses" do
      task_run = %TaskRun{
        task_id: Ecto.UUID.generate(),
        project_id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate()
      }

      changeset = TaskRun.create_changeset(task_run, %{status: "entered"})

      assert %{status: ["is invalid"]} = errors_on(changeset)
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
    test "returns the latest active run scoped to the user, including waiting runs" do
      user = create_user()
      {project, task, _workflow} = create_task_with_workflow(user)
      {:ok, _completed} = TaskRuns.insert(user.id, project.id, task.id, %{status: :completed})
      {:ok, _executing} = TaskRuns.insert(user.id, project.id, task.id, %{status: :executing})
      {:ok, active} = TaskRuns.insert(user.id, project.id, task.id, %{status: :waiting})

      other_user = create_user()

      assert {:ok, found} = TaskRuns.get_active_for_task(user.id, task.id)
      assert found.id == active.id

      assert {:error, :not_found} = TaskRuns.get_active_for_task(other_user.id, task.id)
    end
  end

  describe "list_for_trace/2" do
    test "lists root and child runs scoped to the user" do
      user = create_user()
      {project, task, _workflow} = create_task_with_workflow(user)
      {:ok, root} = TaskRuns.insert(user.id, project.id, task.id)

      {:ok, child} =
        TaskRuns.insert(user.id, project.id, task.id, %{
          parent_task_run_id: root.id,
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

      assert listed_ids == [root.id, child.id]
      refute out_of_scope.id in listed_ids
    end
  end

  describe "step execution association" do
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
        "needs_approval" => true
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
      assert completed_run.failure_kind == nil
      assert completed_run.failure_reason == nil
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
end
