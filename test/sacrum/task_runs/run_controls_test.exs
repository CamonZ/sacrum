defmodule Sacrum.TaskRuns.RunControlsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts
  alias Sacrum.Repo.TaskDependencies
  alias Sacrum.TaskRuns.RunControls

  setup do
    user = create_user()
    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Run controls project"})
    %{user: user, project: project}
  end

  test "returns runnable controls for a schedulable task", %{user: user, project: project} do
    task = create_task(user, project, "Runnable task")

    assert {:ok, controls} = RunControls.for_task(user.id, task.id)
    assert controls.runnable == true
    assert controls.stoppable == false
    assert controls.disabled_reason_code == nil
    assert controls.disabled_reason == nil
    assert controls.active_run == nil
  end

  test "maps non-runnable task states to stable reason codes", %{user: user, project: project} do
    completed = create_task(user, project, "Completed")
    {:ok, completed} = Accounts.Tasks.update(completed, %{completed_at: DateTime.utc_now()})

    archived = create_task(user, project, "Archived")
    {:ok, archived} = Accounts.Tasks.update(archived, %{archived: true})

    missing_workflow = %{create_task(user, project, "Missing workflow") | workflow_id: nil}

    blocker = create_task(user, project, "Incomplete blocker")
    blocked = create_task(user, project, "Blocked")
    {:ok, _dependency} = TaskDependencies.add_dependency(blocked, blocker)

    assert_reason(user, completed, "completed", "Task is already completed")
    assert_reason(user, archived, "archived", "Task is archived")
    assert_presenter_reason(missing_workflow, "missing_workflow", "Task has no workflow assigned")
    assert_reason(user, blocked, "blocked", "Task has incomplete blockers")
  end

  test "stoppable active lifecycle states expose active run data", %{
    user: user,
    project: project
  } do
    for status <- [:queued, :executing, :waiting] do
      task = create_task(user, project, "Active #{status}")
      {:ok, run} = Accounts.TaskRuns.insert(user.id, project.id, task.id, %{status: status})

      assert {:ok, controls} = RunControls.for_task(user.id, task.id)
      assert controls.runnable == false
      assert controls.stoppable == true
      assert controls.disabled_reason_code == "active_run"
      assert controls.disabled_reason == "Task already has an active run"
      assert controls.active_run.id == run.id
      assert RunControls.to_payload(controls).active_run.id == run.id
    end
  end

  test "stopping run exposes active run without advertising another stop action", %{
    user: user,
    project: project
  } do
    task = create_task(user, project, "Stopping")
    {:ok, run} = Accounts.TaskRuns.insert(user.id, project.id, task.id, %{status: :stopping})

    assert {:ok, controls} = RunControls.for_task(user.id, task.id)
    assert controls.runnable == false
    assert controls.stoppable == false
    assert controls.disabled_reason_code == "stopping"
    assert controls.disabled_reason == "Task run is already stopping"
    assert controls.active_run.id == run.id
  end

  test "failed step during an active retry gap remains stoppable", %{
    user: user,
    project: project
  } do
    task = create_task(user, project, "Retry gap")
    {:ok, run} = Accounts.TaskRuns.insert(user.id, project.id, task.id, %{status: :queued})
    {:ok, execution} = create_step_execution(user, task, run.id, "failed")
    {:ok, _run} = Accounts.TaskRuns.update(run, %{latest_step_execution_id: execution.id})

    assert {:ok, controls} = RunControls.for_task(user.id, task.id)
    assert controls.runnable == false
    assert controls.stoppable == true
    assert controls.disabled_reason_code == "active_run"
    assert controls.active_run.latest_step_execution_id == execution.id
  end

  test "waiting run with waiting execution remains active and stoppable", %{
    user: user,
    project: project
  } do
    task = create_task(user, project, "Human input pause")
    {:ok, run} = Accounts.TaskRuns.insert(user.id, project.id, task.id, %{status: :waiting})
    {:ok, execution} = create_step_execution(user, task, run.id, "waiting")
    {:ok, _run} = Accounts.TaskRuns.update(run, %{latest_step_execution_id: execution.id})

    assert {:ok, controls} = RunControls.for_task(user.id, task.id)
    assert controls.runnable == false
    assert controls.stoppable == true
    assert controls.disabled_reason_code == "active_run"
    assert controls.active_run.latest_step_execution_id == execution.id
  end

  test "stale active run with in-flight work is not advertised as safely stoppable", %{
    user: user,
    project: project
  } do
    task = create_task(user, project, "Stale active run")
    {:ok, run} = Accounts.TaskRuns.insert(user.id, project.id, task.id, %{status: :executing})
    {:ok, execution} = create_step_execution(user, task, run.id, "in_progress")
    {:ok, _run} = Accounts.TaskRuns.update(run, %{latest_step_execution_id: execution.id})

    assert {:ok, controls} = RunControls.for_task(user.id, task.id)
    assert controls.runnable == false
    assert controls.stoppable == false
    assert controls.disabled_reason_code == "stale_active_run"
    assert controls.disabled_reason =~ "no orchestrator"
    assert controls.active_run.id == run.id
  end

  defp create_user do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Sacrum.Repo.Users.insert(%{
        email: "run-controls-#{suffix}@example.com",
        username: "run_controls_#{suffix}",
        password: "password123"
      })

    user
  end

  defp create_task(user, project, title) do
    {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: title})
    task
  end

  defp create_step_execution(user, task, task_run_id, status) do
    Accounts.StepExecutions.insert(user.id, %{
      task_id: task.id,
      task_run_id: task_run_id,
      workflow_id: task.workflow_id,
      project_id: task.project_id,
      step_name: "execute",
      step_type: "execute",
      status: status
    })
  end

  defp assert_reason(user, task, code, message) do
    assert {:ok, controls} = RunControls.for_task(user.id, task.id)
    assert_controls_reason(controls, code, message)
  end

  defp assert_presenter_reason(task, code, message) do
    controls = RunControls.present(task, nil, blocked?: false, orchestrator_running?: false)
    assert_controls_reason(controls, code, message)
  end

  defp assert_controls_reason(controls, code, message) do
    assert controls.runnable == false
    assert controls.stoppable == false
    assert controls.disabled_reason_code == code
    assert controls.disabled_reason == message
    assert controls.active_run == nil
  end
end
