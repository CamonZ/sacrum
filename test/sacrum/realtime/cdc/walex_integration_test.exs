defmodule Sacrum.Realtime.Cdc.WalExIntegrationTest do
  use ExUnit.Case, async: false

  import Sacrum.CdcAssertions

  alias Ecto.Adapters.SQL.Sandbox
  alias Sacrum.Orchestrator.{ExecutionDispatcher, PromptRenderer}
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{CodeRef, StepExecution, Task}

  alias Sacrum.Repo.{
    CodeRefs,
    Projects,
    SessionLogs,
    StepTransitions,
    TaskDependencies,
    TaskHierarchy,
    TaskRuns,
    TaskSections,
    Tasks,
    WorkflowSteps,
    WorkflowTransitions,
    Workflows
  }

  alias Sacrum.Repo.Users

  setup do
    committed_db(&cleanup_committed_cdc_rows/0)

    owner = Sandbox.start_owner!(Repo, shared: true)

    slot = "sacrum_cdc_test_#{System.unique_integer([:positive])}"

    config =
      Sacrum.Realtime.Cdc.Config.walex_config()
      |> Keyword.put(:slot_name, slot)
      |> Keyword.put(:durable_slot, false)

    {:ok, walex} = start_supervised({WalEx.Supervisor, config})

    on_exit(fn ->
      shut_down_walex(walex)
      drop_replication_slot(slot)
      Sandbox.stop_owner(owner)
    end)

    :ok
  end

  defp shut_down_walex(walex) do
    if Process.alive?(walex) do
      ref = Process.monitor(walex)
      Process.exit(walex, :shutdown)

      receive do
        {:DOWN, ^ref, :process, ^walex, _reason} -> :ok
      after
        5_000 -> :ok
      end
    end
  end

  defp drop_replication_slot(slot) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.query!(
        """
        SELECT pg_terminate_backend(active_pid)
        FROM pg_replication_slots
        WHERE slot_name = $1 AND active_pid IS NOT NULL
        """,
        [slot]
      )

      Repo.query!(
        """
        SELECT pg_drop_replication_slot(slot_name)
        FROM pg_replication_slots
        WHERE slot_name = $1
        """,
        [slot]
      )
    end)
  rescue
    _ -> :ok
  end

  test "committed task inserts, updates, and deletes are projected to default clients" do
    with_project(fn _user, project ->
      :ok = subscribe_project(project.id)

      {:ok, task} = Tasks.insert(project, %{title: "CDC task"})

      created_payload =
        assert_project_broadcast(
          "task_created",
          %{
            id: task.id,
            title: "CDC task",
            project_id: project.id
          },
          1_000
        )

      assert created_payload.run_controls == %{
               runnable: true,
               stoppable: false,
               disabled_reason_code: nil,
               disabled_reason: nil,
               active_run: nil
             }

      {:ok, updated_task} =
        task
        |> Task.update_changeset(%{title: "CDC task updated"})
        |> Tasks.update()

      updated_payload =
        assert_project_broadcast(
          "task_updated",
          %{
            id: task.id,
            title: "CDC task updated",
            project_id: project.id
          },
          1_000
        )

      assert updated_payload.previous == %{}

      {:ok, _deleted_task} = Tasks.delete(updated_task)

      assert_project_broadcast(
        "task_deleted",
        %{
          id: task.id
        },
        1_000
      )
    end)
  end

  test "task updates publish sparse previous bucket identity fields" do
    with_project(fn _user, project ->
      task = create_task(project, "CDC bucket identity task", %{})
      :ok = subscribe_project(project.id)

      {:ok, archived_task} =
        task
        |> Task.update_changeset(%{archived: true})
        |> Tasks.update()

      archived_payload =
        assert_project_broadcast(
          "task_updated",
          %{id: task.id, archived: true, project_id: project.id},
          1_000
        )

      assert archived_payload.previous == %{archived: false}

      {:ok, _ticket_task} =
        archived_task
        |> Task.update_changeset(%{level: "ticket"})
        |> Tasks.update()

      level_payload =
        assert_project_broadcast(
          "task_updated",
          %{id: task.id, level: "ticket", project_id: project.id},
          1_000
        )

      assert level_payload.previous == %{level: "task"}
    end)
  end

  test "task updates project controls from the current active run" do
    with_project(fn user, project ->
      task = create_task(project, "CDC active task", %{})
      {:ok, task_run} = TaskRuns.insert(user.id, project.id, task.id, %{status: :queued})

      :ok = subscribe_project(project.id)

      {:ok, _updated_task} =
        task
        |> Task.update_changeset(%{title: "CDC active task updated"})
        |> Tasks.update()

      payload =
        assert_project_broadcast(
          "task_updated",
          %{id: task.id, title: "CDC active task updated", project_id: project.id},
          1_000
        )

      assert payload.run_controls.runnable == false
      assert payload.run_controls.stoppable == true
      assert payload.run_controls.disabled_reason_code == "active_run"
      assert payload.run_controls.disabled_reason == "Task already has an active run"
      assert payload.run_controls.active_run.id == task_run.id
      assert payload.run_controls.active_run.status == "queued"
    end)
  end

  test "dispatcher transaction emits compatible task and task run controls" do
    with_project(fn user, project ->
      {_workflow, step, _next_step} = create_workflow_with_steps(user, project)
      task = create_task(project, "CDC dispatched task", %{})
      {:ok, task_run} = TaskRuns.insert(user.id, project.id, task.id, %{status: :queued})
      task = PromptRenderer.preload_for_rendering(task)

      :ok = subscribe_project(project.id)

      {:ok, execution} =
        ExecutionDispatcher.create_and_dispatch(user.id, task, step.id, task_run)

      assert_receive %Phoenix.Socket.Broadcast{event: "step_execution_created"}, 1_000

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "task_run_updated",
                       payload: task_run_payload
                     },
                     1_000

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "task_updated",
                       payload: task_payload
                     },
                     1_000

      assert task_run_payload.id == task_run.id
      assert task_run_payload.status == "executing"
      assert task_run_payload.latest_step_execution_id == execution.id
      assert task_payload.id == task.id
      assert task_payload.run_controls == task_run_payload.run_controls
      assert task_payload.run_controls.runnable == false
      assert task_payload.run_controls.stoppable == false
      assert task_payload.run_controls.disabled_reason_code == "stale_active_run"
      assert task_payload.run_controls.active_run.id == task_run.id
      assert task_payload.run_controls.active_run.latest_step_execution_id == execution.id
    end)
  end

  test "committed workflow inserts and updates are projected" do
    with_project(fn _user, project ->
      :ok = subscribe_project(project.id)

      {:ok, workflow} =
        Workflows.insert(project, %{
          name: "CDC workflow",
          display_order: 2
        })

      assert_project_broadcast(
        "workflow_created",
        %{
          id: workflow.id,
          name: "CDC workflow",
          project_id: project.id
        },
        1_000
      )

      {:ok, _updated_workflow} = Workflows.update(workflow, %{name: "CDC workflow updated"})

      assert_project_broadcast(
        "workflow_updated",
        %{
          id: workflow.id,
          name: "CDC workflow updated",
          project_id: project.id
        },
        1_000
      )
    end)
  end

  test "committed workflow deletes are projected" do
    with_project(fn _user, project ->
      :ok = subscribe_project(project.id)

      {:ok, workflow} = Workflows.insert(project, %{name: "CDC delete workflow"})

      assert_project_broadcast(
        "workflow_created",
        %{
          id: workflow.id,
          project_id: project.id
        },
        1_000
      )

      {:ok, _deleted_workflow} = Workflows.delete(workflow)

      assert_project_broadcast(
        "workflow_deleted",
        %{id: workflow.id},
        1_000
      )
    end)
  end

  test "committed workflow step inserts and updates are projected" do
    with_project(fn user, project ->
      {workflow, _first_step, _second_step} = create_workflow_with_steps(user, project)

      :ok = subscribe_project(project.id)

      {:ok, step} =
        WorkflowSteps.insert(workflow, %{
          name: "CDC created step",
          step_order: 3,
          step_type: "execute"
        })

      assert_project_broadcast(
        "step_created",
        %{
          id: step.id,
          name: "CDC created step",
          workflow_id: workflow.id,
          project_id: project.id
        },
        1_000
      )

      {:ok, _updated_step} = WorkflowSteps.update(step, %{name: "CDC updated step"})

      assert_project_broadcast(
        "step_updated",
        %{
          id: step.id,
          name: "CDC updated step",
          workflow_id: workflow.id,
          project_id: project.id
        },
        1_000
      )
    end)
  end

  test "committed workflow step deletes are projected" do
    with_project(fn user, project ->
      {workflow, _first_step, _second_step} = create_workflow_with_steps(user, project)

      {:ok, step} =
        WorkflowSteps.insert(workflow, %{
          name: "CDC step delete",
          step_order: 3,
          step_type: "execute"
        })

      :ok = subscribe_project(project.id)

      {:ok, _deleted_step} = Repo.delete(step)

      assert_project_broadcast(
        "step_deleted",
        %{
          id: step.id,
          workflow_id: workflow.id
        },
        1_000
      )
    end)
  end

  test "committed step transition inserts and deletes are projected" do
    with_project(fn user, project ->
      {_workflow, from_step, to_step} = create_workflow_with_steps(user, project)

      :ok = subscribe_project(project.id)

      {:ok, transition} =
        StepTransitions.insert(user.id, %{
          from_step_id: from_step.id,
          to_step_id: to_step.id,
          project_id: project.id,
          label: "continue"
        })

      assert_project_broadcast(
        "step_transition_created",
        %{
          id: transition.id,
          from_step_id: from_step.id,
          to_step_id: to_step.id,
          project_id: project.id
        },
        1_000
      )

      {:ok, _deleted_transition} = Repo.delete(transition)

      assert_project_broadcast(
        "step_transition_deleted",
        %{
          id: transition.id,
          from_step_id: from_step.id,
          to_step_id: to_step.id,
          project_id: project.id
        },
        1_000
      )
    end)
  end

  test "committed workflow transition inserts and deletes are projected" do
    with_project(fn user, project ->
      {source_workflow, _source_step, _second_step} = create_workflow_with_steps(user, project)
      {target_workflow, target_step, _unused_step} = create_workflow_with_steps(user, project)

      :ok = subscribe_project(project.id)

      {:ok, transition} =
        WorkflowTransitions.insert(user.id, %{
          from_workflow_id: source_workflow.id,
          to_workflow_id: target_workflow.id,
          target_step_id: target_step.id,
          project_id: project.id,
          label: "handoff"
        })

      assert_project_broadcast(
        "workflow_transition_created",
        %{
          id: transition.id,
          from_workflow_id: source_workflow.id,
          to_workflow_id: target_workflow.id,
          target_step_id: target_step.id,
          project_id: project.id
        },
        1_000
      )

      {:ok, _deleted_transition} = Repo.delete(transition)

      assert_project_broadcast(
        "workflow_transition_deleted",
        %{
          id: transition.id,
          from_workflow_id: source_workflow.id,
          to_workflow_id: target_workflow.id,
          target_step_id: target_step.id,
          project_id: project.id
        },
        1_000
      )
    end)
  end

  test "committed task parent changes are projected" do
    with_project(fn user, project ->
      {workflow, _first_step, _second_step} = create_workflow_with_steps(user, project)
      parent = create_task(project, "CDC parent", %{workflow_id: workflow.id})
      child = create_task(project, "CDC child", %{workflow_id: workflow.id})

      :ok = subscribe_project(project.id)

      {:ok, _parented_child} = TaskHierarchy.set_parent(child, parent)

      assert_project_broadcast(
        "task_parent_changed",
        %{
          task_id: child.id,
          project_id: project.id,
          from_parent_id: nil,
          to_parent_id: parent.id,
          level: "task"
        },
        1_000
      )
    end)
  end

  test "committed manual task step changes are projected" do
    with_project(fn user, project ->
      {workflow, first_step, second_step} = create_workflow_with_steps(user, project)
      task = create_task(project, "CDC step move", %{workflow_id: workflow.id})

      :ok = subscribe_project(project.id)

      {:ok, _moved_task} =
        task
        |> Task.assign_workflow_changeset(workflow.id, second_step.id)
        |> Repo.update()

      assert_project_broadcast(
        "task_step_changed",
        %{
          task_id: task.id,
          from_step_id: first_step.id,
          to_step_id: second_step.id,
          workflow_id: workflow.id,
          level: "task"
        },
        1_000
      )
    end)
  end

  test "committed task dependency inserts and deletes are projected" do
    with_project(fn user, project ->
      {workflow, _first_step, _second_step} = create_workflow_with_steps(user, project)
      task = create_task(project, "CDC dependent", %{workflow_id: workflow.id})
      blocker = create_task(project, "CDC blocker", %{workflow_id: workflow.id})

      :ok = subscribe_project(project.id)

      {:ok, dependency} = TaskDependencies.add_dependency(task, blocker)

      assert_project_broadcast(
        "task_dependency_created",
        %{
          id: dependency.id,
          task_id: task.id,
          depends_on_id: blocker.id,
          project_id: project.id
        },
        1_000
      )

      {:ok, _deleted_dependency} = TaskDependencies.remove_dependency(task, blocker)

      assert_project_broadcast(
        "task_dependency_deleted",
        %{
          id: dependency.id,
          task_id: task.id,
          depends_on_id: blocker.id,
          project_id: project.id
        },
        1_000
      )
    end)
  end

  test "committed task section inserts and updates are projected" do
    with_project(fn user, project ->
      {workflow, _first_step, _second_step} = create_workflow_with_steps(user, project)
      task = create_task(project, "CDC section task", %{workflow_id: workflow.id})

      :ok = subscribe_project(project.id)

      {:ok, section} =
        TaskSections.insert(task, %{
          section_type: "context",
          content: "CDC section",
          section_order: 1
        })

      assert_project_broadcast(
        "section_created",
        %{
          id: section.id,
          task_id: task.id,
          project_id: project.id,
          content: "CDC section"
        },
        1_000
      )

      {:ok, _updated_section} = TaskSections.update(section, %{content: "CDC section updated"})

      assert_project_broadcast(
        "section_updated",
        %{
          id: section.id,
          task_id: task.id,
          project_id: project.id,
          content: "CDC section updated"
        },
        1_000
      )
    end)
  end

  test "committed task section deletes are projected" do
    with_project(fn user, project ->
      {workflow, _first_step, _second_step} = create_workflow_with_steps(user, project)
      task = create_task(project, "CDC section delete task", %{workflow_id: workflow.id})

      {:ok, section} =
        TaskSections.insert(task, %{
          section_type: "context",
          content: "CDC section",
          section_order: 1
        })

      :ok = subscribe_project(project.id)

      {:ok, _deleted_section} = TaskSections.delete(section)

      assert_project_broadcast(
        "section_deleted",
        %{
          id: section.id,
          task_id: task.id
        },
        1_000
      )
    end)
  end

  test "committed code ref inserts and updates are projected" do
    with_project(fn user, project ->
      {workflow, _first_step, _second_step} = create_workflow_with_steps(user, project)
      task = create_task(project, "CDC code ref task", %{workflow_id: workflow.id})

      :ok = subscribe_project(project.id)

      {:ok, code_ref} =
        CodeRefs.insert_for_task(task, %{
          path: "lib/sacrum/realtime/cdc/projector.ex",
          line_start: 1,
          line_end: 5,
          name: "CDC projector"
        })

      assert_project_broadcast(
        "code_ref_created",
        %{
          id: code_ref.id,
          task_id: task.id,
          project_id: project.id,
          path: "lib/sacrum/realtime/cdc/projector.ex"
        },
        1_000
      )

      {:ok, _updated_code_ref} =
        code_ref
        |> CodeRef.changeset(%{name: "CDC projector updated", line_end: 10})
        |> Repo.update()

      assert_project_broadcast(
        "code_ref_updated",
        %{
          id: code_ref.id,
          task_id: task.id,
          project_id: project.id,
          name: "CDC projector updated",
          line_end: 10
        },
        1_000
      )
    end)
  end

  test "committed code ref deletes are projected" do
    with_project(fn user, project ->
      {workflow, _first_step, _second_step} = create_workflow_with_steps(user, project)
      task = create_task(project, "CDC code ref delete task", %{workflow_id: workflow.id})

      {:ok, code_ref} =
        CodeRefs.insert_for_task(task, %{
          path: "lib/sacrum/realtime/cdc/projector.ex",
          line_start: 1,
          line_end: 5,
          name: "CDC projector"
        })

      :ok = subscribe_project(project.id)

      {:ok, _deleted_code_ref} = Repo.delete(code_ref)

      assert_project_broadcast(
        "code_ref_deleted",
        %{
          id: code_ref.id,
          task_id: task.id,
          project_id: project.id,
          path: "lib/sacrum/realtime/cdc/projector.ex"
        },
        1_000
      )
    end)
  end

  test "committed task run inserts and terminal updates are projected" do
    with_project(fn user, project ->
      {workflow, step, _next_step} = create_workflow_with_steps(user, project)
      task = create_task(project, "CDC task run", %{workflow_id: workflow.id})

      :ok = subscribe_project(project.id)

      {:ok, task_run} = TaskRuns.insert(user.id, project.id, task.id, %{status: :executing})

      assert_project_broadcast(
        "task_run_created",
        %{
          id: task_run.id,
          task_id: task.id,
          project_id: project.id,
          status: "executing"
        },
        1_000
      )

      assert_project_broadcast(
        "task_run_step_changed",
        %{
          task_run_id: task_run.id,
          task_id: task.id,
          from_step_id: nil,
          to_step_id: step.id,
          status: "executing",
          level: "task"
        },
        1_000
      )

      {:ok, _completed_task_run} =
        TaskRuns.update(task_run, %{
          status: :completed,
          outcome_kind: "step_completed",
          outcome_context: %{"source" => "cdc-test"}
        })

      assert_project_broadcast(
        "task_run_updated",
        %{
          id: task_run.id,
          task_id: task.id,
          project_id: project.id,
          status: "completed"
        },
        1_000
      )

      assert_project_broadcast(
        "task_run_step_changed",
        %{
          task_run_id: task_run.id,
          task_id: task.id,
          from_step_id: step.id,
          to_step_id: nil,
          status: "completed",
          level: "task"
        },
        1_000
      )
    end)
  end

  test "committed step execution inserts and status changes are projected" do
    with_project(fn user, project ->
      {workflow, step, _next_step} = create_workflow_with_steps(user, project)
      task = create_task(project, "CDC execution", %{workflow_id: workflow.id})
      {:ok, task_run} = TaskRuns.insert(user.id, project.id, task.id, %{status: :executing})

      :ok = subscribe_project(project.id)

      {:ok, execution} =
        %StepExecution{user_id: user.id, task_id: task.id, project_id: project.id}
        |> StepExecution.create_changeset(%{
          task_id: task.id,
          task_run_id: task_run.id,
          workflow_id: workflow.id,
          step_id: step.id,
          step_name: step.name,
          status: "started"
        })
        |> Repo.insert()

      assert_project_broadcast(
        "step_execution_created",
        %{
          id: execution.id,
          task_id: task.id,
          task_run_id: task_run.id,
          project_id: project.id,
          status: "started"
        },
        1_000
      )

      {:ok, _updated_execution} =
        execution
        |> StepExecution.update_changeset(%{status: "completed"})
        |> Repo.update()

      assert_project_broadcast(
        "step_execution_status_changed",
        %{
          id: execution.id,
          task_id: task.id,
          task_run_id: task_run.id,
          status: "completed",
          project_id: project.id
        },
        1_000
      )
    end)
  end

  test "committed session log inserts are projected" do
    with_project(fn user, project ->
      {workflow, step, _next_step} = create_workflow_with_steps(user, project)
      task = create_task(project, "CDC session log", %{workflow_id: workflow.id})

      {:ok, execution} =
        %StepExecution{user_id: user.id, task_id: task.id, project_id: project.id}
        |> StepExecution.create_changeset(%{
          task_id: task.id,
          workflow_id: workflow.id,
          step_id: step.id,
          step_name: step.name,
          status: "started"
        })
        |> Repo.insert()

      :ok = subscribe_project(project.id)

      {:ok, log} =
        SessionLogs.insert(user.id, %{
          step_execution_id: execution.id,
          project_id: project.id,
          content: "CDC log"
        })

      assert_project_broadcast(
        "session_log_created",
        %{
          id: log.id,
          step_execution_id: execution.id,
          project_id: project.id,
          content: "CDC log"
        },
        1_000
      )
    end)
  end

  test "logical-key session log mutations project created then updated" do
    with_project(fn user, project ->
      {workflow, step, _next_step} = create_workflow_with_steps(user, project)
      task = create_task(project, "CDC logical session log", %{workflow_id: workflow.id})

      {:ok, execution} =
        %StepExecution{user_id: user.id, task_id: task.id, project_id: project.id}
        |> StepExecution.create_changeset(%{
          task_id: task.id,
          workflow_id: workflow.id,
          step_id: step.id,
          step_name: step.name,
          status: "started"
        })
        |> Repo.insert()

      :ok = subscribe_project(project.id)

      first_log =
        run_graphql!(user, """
        mutation {
          createSessionLog(
            stepExecutionId: "#{execution.id}"
            logicalKey: "system/thinking_tokens"
            content: "first snapshot"
            format: "anthropic"
          ) { id content logicalKey }
        }
        """)
        |> get_in(["createSessionLog"])

      assert first_log["content"] == "first snapshot"
      assert first_log["logicalKey"] == "system/thinking_tokens"

      created_payload =
        assert_project_broadcast(
          "session_log_created",
          %{
            id: first_log["id"],
            step_execution_id: execution.id,
            project_id: project.id,
            content: "first snapshot",
            logical_key: "system/thinking_tokens"
          },
          1_000
        )

      second_log =
        run_graphql!(user, """
        mutation {
          createSessionLog(
            stepExecutionId: "#{execution.id}"
            logicalKey: "system/thinking_tokens"
            content: "latest snapshot"
            format: "anthropic"
          ) { id content logicalKey }
        }
        """)
        |> get_in(["createSessionLog"])

      assert second_log["id"] == first_log["id"]
      assert second_log["content"] == "latest snapshot"

      updated_payload =
        assert_project_broadcast(
          "session_log_updated",
          %{
            id: first_log["id"],
            step_execution_id: execution.id,
            project_id: project.id,
            content: "latest snapshot",
            logical_key: "system/thinking_tokens"
          },
          1_000
        )

      assert updated_payload.inserted_at == created_payload.inserted_at

      listed_logs =
        run_graphql!(user, """
        {
          sessionLogs(stepExecutionId: "#{execution.id}") {
            id
            content
            logicalKey
          }
        }
        """)
        |> get_in(["sessionLogs"])

      assert [
               %{
                 "id" => id,
                 "content" => "latest snapshot",
                 "logicalKey" => "system/thinking_tokens"
               }
             ] = listed_logs

      assert id == first_log["id"]
    end)
  end

  defp committed_db(fun) do
    Sandbox.unboxed_run(Repo, fun)
  end

  defp run_graphql!(user, document) do
    assert {:ok, %{data: data}} =
             Absinthe.run(document, SacrumWeb.Graphql.Schema, context: %{current_user: user})

    data
  end

  defp with_project(fun) do
    committed_db(fn ->
      {user, project} = create_project()

      try do
        fun.(user, project)
      after
        cleanup_user(user.id)
      end
    end)
  end

  defp create_workflow_with_steps(user, project) do
    suffix = System.unique_integer([:positive])

    {:ok, workflow} =
      Workflows.insert(project, %{
        name: "CDC support workflow #{suffix}",
        display_order: 10
      })

    {:ok, first_step} =
      WorkflowSteps.insert(workflow, %{
        name: "CDC support first #{suffix}",
        step_order: 1,
        step_type: "execute"
      })

    {:ok, second_step} =
      WorkflowSteps.insert(workflow, %{
        name: "CDC support second #{suffix}",
        step_order: 2,
        step_type: "execute"
      })

    {:ok, workflow} = Workflows.update(workflow, %{initial_step_id: first_step.id})

    {Map.put(workflow, :user_id, user.id), first_step, second_step}
  end

  defp create_task(project, title, attrs) do
    {:ok, task} =
      project
      |> Tasks.insert(Map.put(attrs, :title, title))

    task
  end

  defp create_project do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Users.insert(%{
        email: "real-cdc-#{suffix}@example.com",
        username: "real_cdc_#{suffix}",
        password: "password123"
      })

    {:ok, project} = Projects.insert(user, %{name: "Real CDC #{suffix}"})

    drain_project_broadcasts()

    {user, project}
  end

  defp drain_project_broadcasts do
    receive do
      %Phoenix.Socket.Broadcast{} -> drain_project_broadcasts()
    after
      0 -> :ok
    end
  end

  defp cleanup_user(user_id) do
    user_id
    |> project_ids_for_user()
    |> Enum.each(&cleanup_project/1)

    Repo.query!("DELETE FROM users WHERE id = $1", [uuid_param(user_id)])
  end

  defp cleanup_committed_cdc_rows do
    %{rows: rows} =
      Repo.query!("SELECT id FROM users WHERE email LIKE 'real-cdc-%@example.com'", [])

    rows
    |> List.flatten()
    |> Enum.each(&cleanup_user/1)
  end

  defp project_ids_for_user(user_id) do
    %{rows: rows} =
      Repo.query!("SELECT id FROM projects WHERE user_id = $1", [uuid_param(user_id)])

    List.flatten(rows)
  end

  defp cleanup_project(project_id) do
    project_id = uuid_param(project_id)

    Repo.query!(
      """
      UPDATE task_runs
      SET latest_step_execution_id = NULL,
          triggered_by_step_execution_id = NULL
      WHERE project_id = $1
      """,
      [project_id]
    )

    Repo.query!("UPDATE step_executions SET task_run_id = NULL WHERE project_id = $1", [
      project_id
    ])

    for table <- [
          "session_logs",
          "code_refs",
          "task_sections",
          "task_dependencies",
          "step_transitions",
          "workflow_transitions",
          "task_runs",
          "step_executions",
          "tasks",
          "workflow_steps",
          "workflows"
        ] do
      Repo.query!("DELETE FROM #{table} WHERE project_id = $1", [project_id])
    end

    Repo.query!("DELETE FROM projects WHERE id = $1", [project_id])
  end

  defp uuid_param(<<_::128>> = id), do: id

  defp uuid_param(id) do
    {:ok, uuid} = Ecto.UUID.dump(id)
    uuid
  end
end
