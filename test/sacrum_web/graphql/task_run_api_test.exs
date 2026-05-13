defmodule SacrumWeb.Graphql.TaskRunApiTest do
  use SacrumWeb.ConnCase

  alias Sacrum.Accounts
  alias Sacrum.Repo.TaskDependencies

  defp graphql(conn, query) do
    post(conn, "/graphql", %{"query" => query})
  end

  defp graphql_result(conn, user, query) do
    conn
    |> authenticate(user)
    |> graphql(query)
    |> json_response(200)
  end

  defp setup_user_and_project(_context) do
    user = create_user()
    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "TaskRun API Project"})
    %{user: user, project: project}
  end

  defp create_task(user, project, title) do
    {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: title})
    task
  end

  defp create_workflow_task(user, project) do
    task = create_task(user, project, "Runnable task")
    {:ok, workflow} = Accounts.Workflows.insert(user.id, project.id, %{name: "Workflow"})
    {:ok, _step} = Accounts.WorkflowSteps.insert(workflow, %{name: "execute", goal: "Run"})
    {:ok, task} = Sacrum.Repo.TaskWorkflows.assign_workflow(task, workflow)

    {task, workflow}
  end

  defp run_controls_result(conn, user, task_id) do
    result =
      graphql_result(conn, user, """
      {
        task(id: "#{task_id}") {
          id
          runControls {
            runnable
            stoppable
            disabledReasonCode
            disabledReason
            activeRun {
              id
              taskId
              status
              latestStepExecutionId
            }
          }
        }
      }
      """)

    assert result["errors"] == nil
    result["data"]["task"]["runControls"]
  end

  defp create_step_execution(user, task, task_run_id, status) do
    Accounts.StepExecutions.insert(user.id, %{
      task_id: task.id,
      task_run_id: task_run_id,
      project_id: task.project_id,
      workflow_id: task.workflow_id,
      step_name: "execute",
      status: status
    })
  end

  defp assert_runnable(controls) do
    assert controls["runnable"] == true
    assert controls["stoppable"] == false
    assert controls["disabledReasonCode"] == nil
    assert controls["disabledReason"] == nil
    assert controls["activeRun"] == nil
  end

  defp assert_disabled(controls, reason_code) do
    assert controls["runnable"] == false
    assert controls["stoppable"] == false
    assert controls["disabledReasonCode"] == reason_code
    assert is_binary(controls["disabledReason"])
    assert controls["activeRun"] == nil
  end

  defp stop_if_running(task_id) do
    case Registry.lookup(Sacrum.Orchestrator.TaskRegistry, task_id) do
      [{pid, _}] ->
        Ecto.Adapters.SQL.Sandbox.allow(Sacrum.Repo, self(), pid)
        Sacrum.Orchestrator.stop(task_id)

      [] ->
        :ok
    end
  end

  describe "TaskRun GraphQL queries" do
    setup [:setup_user_and_project]

    test "activeRun returns active lifecycle states and null when none exists", %{
      conn: conn,
      user: user,
      project: project
    } do
      for status <- [:queued, :executing, :waiting, :stopping] do
        task = create_task(user, project, "Active #{status}")
        {:ok, run} = Accounts.TaskRuns.insert(user.id, project.id, task.id, %{status: status})

        result =
          graphql_result(conn, user, """
          {
            activeRun(taskId: "#{task.id}") {
              id
              taskId
              status
            }
          }
          """)

        assert result["errors"] == nil
        assert result["data"]["activeRun"]["id"] == run.id
        assert result["data"]["activeRun"]["taskId"] == task.id
        assert result["data"]["activeRun"]["status"] == Atom.to_string(status)
      end

      completed_task = create_task(user, project, "Completed run task")

      {:ok, _run} =
        Accounts.TaskRuns.insert(user.id, project.id, completed_task.id, %{status: :completed})

      no_run_task = create_task(user, project, "No run task")

      completed_result =
        graphql_result(conn, user, """
        { activeRun(taskId: "#{completed_task.id}") { id status } }
        """)

      no_run_result =
        graphql_result(conn, user, """
        { activeRun(taskId: "#{no_run_task.id}") { id status } }
        """)

      assert completed_result["errors"] == nil
      assert completed_result["data"]["activeRun"] == nil
      assert no_run_result["errors"] == nil
      assert no_run_result["data"]["activeRun"] == nil
    end

    test "taskRunTrace returns descendant runs, executions, and logs in deterministic order", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, workflow} = Accounts.Workflows.insert(user.id, project.id, %{name: "Trace workflow"})
      root_task = create_task(user, project, "Root task")
      child_task = create_task(user, project, "Child task")
      grandchild_task = create_task(user, project, "Grandchild task")

      {:ok, root} = Accounts.TaskRuns.insert(user.id, project.id, root_task.id)

      {:ok, child} =
        Accounts.TaskRuns.insert(user.id, project.id, child_task.id, %{
          parent_task_run_id: root.id,
          root_task_run_id: root.id
        })

      {:ok, grandchild} =
        Accounts.TaskRuns.insert(user.id, project.id, grandchild_task.id, %{
          parent_task_run_id: child.id,
          root_task_run_id: root.id
        })

      {:ok, root_execution} =
        Accounts.StepExecutions.insert(user.id, %{
          task_id: root_task.id,
          task_run_id: root.id,
          project_id: project.id,
          workflow_id: workflow.id,
          step_name: "01_root",
          status: "completed"
        })

      {:ok, child_execution} =
        Accounts.StepExecutions.insert(user.id, %{
          task_id: child_task.id,
          task_run_id: child.id,
          project_id: project.id,
          workflow_id: workflow.id,
          step_name: "02_child",
          status: "completed"
        })

      {:ok, grandchild_execution} =
        Accounts.StepExecutions.insert(user.id, %{
          task_id: grandchild_task.id,
          task_run_id: grandchild.id,
          project_id: project.id,
          workflow_id: workflow.id,
          step_name: "03_grandchild",
          status: "completed"
        })

      {:ok, legacy_execution} =
        Accounts.StepExecutions.insert(user.id, %{
          task_id: root_task.id,
          project_id: project.id,
          workflow_id: workflow.id,
          step_name: "legacy_without_task_run",
          status: "completed"
        })

      {:ok, root_log} =
        Accounts.SessionLogs.insert(user.id, %{
          project_id: project.id,
          step_execution_id: root_execution.id,
          content: "root output"
        })

      {:ok, child_log} =
        Accounts.SessionLogs.insert(user.id, %{
          project_id: project.id,
          step_execution_id: child_execution.id,
          content: "child output"
        })

      {:ok, grandchild_log} =
        Accounts.SessionLogs.insert(user.id, %{
          project_id: project.id,
          step_execution_id: grandchild_execution.id,
          content: "grandchild output"
        })

      {:ok, legacy_log} =
        Accounts.SessionLogs.insert(user.id, %{
          project_id: project.id,
          step_execution_id: legacy_execution.id,
          content: "legacy output"
        })

      result =
        graphql_result(conn, user, """
        {
          taskRunTrace(rootTaskRunId: "#{root.id}") {
            rootTaskRunId
            taskRuns {
              id
              taskId
              parentTaskRunId
              rootTaskRunId
              status
            }
            stepExecutions {
              id
              taskRunId
              stepName
              sessionLogs { id content }
            }
            sessionLogs {
              id
              stepExecutionId
              content
            }
          }
        }
        """)

      assert result["errors"] == nil

      trace = result["data"]["taskRunTrace"]
      assert trace["rootTaskRunId"] == root.id
      assert Enum.map(trace["taskRuns"], & &1["id"]) == [root.id, child.id, grandchild.id]

      assert Enum.map(trace["stepExecutions"], & &1["id"]) == [
               root_execution.id,
               child_execution.id,
               grandchild_execution.id
             ]

      assert Enum.map(trace["sessionLogs"], & &1["id"]) == [
               root_log.id,
               child_log.id,
               grandchild_log.id
             ]

      refute legacy_execution.id in Enum.map(trace["stepExecutions"], & &1["id"])
      refute legacy_log.id in Enum.map(trace["sessionLogs"], & &1["id"])

      assert [
               %{"sessionLogs" => [%{"content" => "root output"}]},
               %{"sessionLogs" => [%{"content" => "child output"}]},
               %{"sessionLogs" => [%{"content" => "grandchild output"}]}
             ] = trace["stepExecutions"]
    end

    test "taskRun and taskRunTrace enforce user ownership", %{
      conn: conn,
      user: user,
      project: project
    } do
      task = create_task(user, project, "Owned task")
      {:ok, root} = Accounts.TaskRuns.insert(user.id, project.id, task.id)

      other_user =
        create_user(%{
          email: "other-task-run@example.com",
          username: "other_task_run"
        })

      task_run_result =
        graphql_result(conn, other_user, """
        { taskRun(id: "#{root.id}") { id } }
        """)

      trace_result =
        graphql_result(conn, other_user, """
        { taskRunTrace(rootTaskRunId: "#{root.id}") { rootTaskRunId } }
        """)

      assert task_run_result["data"]["taskRun"] == nil
      assert [%{"message" => _}] = task_run_result["errors"]
      assert trace_result["data"]["taskRunTrace"] == nil
      assert [%{"message" => _}] = trace_result["errors"]
    end
  end

  describe "runControls GraphQL contract" do
    setup [:setup_user_and_project]

    test "returns stoppable controls for actionable active TaskRun lifecycle states", %{
      conn: conn,
      user: user,
      project: project
    } do
      for status <- [:queued, :executing, :waiting] do
        task = create_task(user, project, "Controls #{status}")
        {:ok, run} = Accounts.TaskRuns.insert(user.id, project.id, task.id, %{status: status})

        controls = run_controls_result(conn, user, task.id)

        assert controls["runnable"] == false
        assert controls["stoppable"] == true
        assert controls["disabledReasonCode"] == "active_run"
        assert controls["disabledReason"] == "Task already has an active run"
        assert controls["activeRun"]["id"] == run.id
        assert controls["activeRun"]["taskId"] == task.id
        assert controls["activeRun"]["status"] == Atom.to_string(status)
      end
    end

    test "returns stable disabled controls for stopping TaskRuns", %{
      conn: conn,
      user: user,
      project: project
    } do
      task = create_task(user, project, "Controls stopping")
      {:ok, run} = Accounts.TaskRuns.insert(user.id, project.id, task.id, %{status: :stopping})

      controls = run_controls_result(conn, user, task.id)

      assert controls["runnable"] == false
      assert controls["stoppable"] == false
      assert controls["disabledReasonCode"] == "stopping"
      assert controls["disabledReason"] == "Task run is already stopping"
      assert controls["activeRun"]["id"] == run.id
      assert controls["activeRun"]["taskId"] == task.id
      assert controls["activeRun"]["status"] == "stopping"
    end

    test "returns runnable controls with no active run and reason codes for disabled tasks", %{
      conn: conn,
      user: user,
      project: project
    } do
      {runnable_task, _workflow} = create_workflow_task(user, project)
      assert_runnable(run_controls_result(conn, user, runnable_task.id))

      completed = create_task(user, project, "Completed controls")
      {:ok, completed} = Accounts.Tasks.update(completed, %{completed_at: DateTime.utc_now()})

      archived = create_task(user, project, "Archived controls")
      {:ok, archived} = Accounts.Tasks.update(archived, %{archived: true})

      blocker = create_task(user, project, "Controls blocker")
      blocked = create_task(user, project, "Blocked controls")
      {:ok, _dependency} = TaskDependencies.add_dependency(blocked, blocker)

      assert_disabled(run_controls_result(conn, user, completed.id), "completed")
      assert_disabled(run_controls_result(conn, user, archived.id), "archived")
      assert_disabled(run_controls_result(conn, user, blocked.id), "blocked")
    end

    test "keeps Stop state during active retry gaps with a latest failed step", %{
      conn: conn,
      user: user,
      project: project
    } do
      {task, _workflow} = create_workflow_task(user, project)
      {:ok, run} = Accounts.TaskRuns.insert(user.id, project.id, task.id, %{status: :queued})
      {:ok, execution} = create_step_execution(user, task, run.id, "failed")
      {:ok, _run} = Accounts.TaskRuns.update(run, %{latest_step_execution_id: execution.id})

      controls = run_controls_result(conn, user, task.id)

      assert controls["runnable"] == false
      assert controls["stoppable"] == true
      assert controls["disabledReasonCode"] == "active_run"
      assert controls["activeRun"]["id"] == run.id
      assert controls["activeRun"]["latestStepExecutionId"] == execution.id
    end

    test "calling stopRun twice leaves runControls stable for a fresh query", %{
      conn: conn,
      user: user,
      project: project
    } do
      {task, _workflow} = create_workflow_task(user, project)
      {:ok, run} = Accounts.TaskRuns.insert(user.id, project.id, task.id, %{status: :queued})

      first_stop =
        graphql_result(conn, user, """
        mutation {
          stopRun(taskId: "#{task.id}") {
            id
            status
          }
        }
        """)

      second_stop =
        graphql_result(conn, user, """
        mutation {
          stopRun(taskId: "#{task.id}") {
            id
            status
          }
        }
        """)

      assert first_stop["errors"] == nil
      assert first_stop["data"]["stopRun"]["id"] == run.id
      assert first_stop["data"]["stopRun"]["status"] == "stopped"
      assert second_stop["errors"] == nil
      assert second_stop["data"]["stopRun"] == nil
      assert_runnable(run_controls_result(conn, user, task.id))
    end
  end

  describe "TaskRun GraphQL mutations" do
    setup [:setup_user_and_project]

    test "runWorkflow starts a TaskRun", %{
      conn: conn,
      user: user,
      project: project
    } do
      {task, _workflow} = create_workflow_task(user, project)

      run_result =
        graphql_result(conn, user, """
        mutation {
          runWorkflow(taskId: "#{task.id}") {
            id
            taskId
            status
          }
        }
        """)

      assert run_result["errors"] == nil
      run = run_result["data"]["runWorkflow"]
      assert run["taskId"] == task.id
      assert run["status"] in ["queued", "executing", "waiting", "stopping"]

      stop_if_running(task.id)
    end

    test "stopRun stops a supplied run id", %{
      conn: conn,
      user: user,
      project: project
    } do
      task = create_task(user, project, "Stoppable by run id")
      {:ok, run} = Accounts.TaskRuns.insert(user.id, project.id, task.id, %{status: :queued})

      stop_result =
        graphql_result(conn, user, """
        mutation {
          stopRun(taskRunId: "#{run.id}") {
            id
            status
            stopRequestedAt
            endedAt
          }
        }
        """)

      assert stop_result["errors"] == nil
      stopped = stop_result["data"]["stopRun"]
      assert stopped["id"] == run.id
      assert stopped["status"] == "stopped"
      assert stopped["stopRequestedAt"] != nil
      assert stopped["endedAt"] != nil
    end

    test "stopRun stops the active run by task id and returns null when none is active", %{
      conn: conn,
      user: user,
      project: project
    } do
      task = create_task(user, project, "Stoppable task")
      {:ok, run} = Accounts.TaskRuns.insert(user.id, project.id, task.id, %{status: :queued})

      stop_result =
        graphql_result(conn, user, """
        mutation {
          stopRun(taskId: "#{task.id}") {
            id
            status
          }
        }
        """)

      assert stop_result["errors"] == nil
      assert stop_result["data"]["stopRun"]["id"] == run.id
      assert stop_result["data"]["stopRun"]["status"] == "stopped"

      no_active_result =
        graphql_result(conn, user, """
        mutation {
          stopRun(taskId: "#{task.id}") {
            id
            status
          }
        }
        """)

      assert no_active_result["errors"] == nil
      assert no_active_result["data"]["stopRun"] == nil
    end

    test "stopRun rejects ambiguous identifiers", %{
      conn: conn,
      user: user,
      project: project
    } do
      task = create_task(user, project, "Ambiguous stop task")
      {:ok, run} = Accounts.TaskRuns.insert(user.id, project.id, task.id, %{status: :queued})

      stop_result =
        graphql_result(conn, user, """
        mutation {
          stopRun(taskId: "#{task.id}", taskRunId: "#{run.id}") {
            id
          }
        }
        """)

      assert stop_result["data"]["stopRun"] == nil

      assert [%{"message" => "Provide exactly one of taskId or taskRunId"}] =
               stop_result["errors"]
    end
  end

  describe "TaskRun lifecycle broadcasts" do
    setup [:setup_user_and_project]

    test "returns creation and update payload fields used by realtime clients", %{
      conn: conn,
      user: user,
      project: project
    } do
      task = create_task(user, project, "Broadcast task")

      {:ok, run} = Accounts.TaskRuns.insert(user.id, project.id, task.id, %{status: :queued})

      assert run.id
      assert run.task_id == task.id
      assert run.status == :queued
      created_controls = run_controls_result(conn, user, task.id)
      assert created_controls["activeRun"]["id"] == run.id
      assert created_controls["activeRun"]["status"] == "queued"

      {:ok, updated} = Accounts.TaskRuns.update(run, %{status: :waiting})

      assert updated.id == run.id
      assert updated.status == :waiting
      updated_controls = run_controls_result(conn, user, task.id)
      assert updated_controls["activeRun"]["id"] == updated.id
      assert updated_controls["activeRun"]["status"] == "waiting"
    end
  end
end
