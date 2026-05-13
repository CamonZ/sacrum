defmodule Sacrum.Realtime.Cdc.ProjectorTest do
  use Sacrum.DataCase, async: false

  import Ecto.Query
  import Sacrum.CdcAssertions

  alias Sacrum.Repo
  alias Sacrum.Repo.CodeRefs
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Schemas.{CodeRef, Task}
  alias Sacrum.Repo.Schemas.Workflow
  alias Sacrum.Repo.Schemas.WorkflowStep
  alias Sacrum.Repo.StepTransitions
  alias Sacrum.Repo.TaskDependencies
  alias Sacrum.Repo.TaskSections
  alias Sacrum.Repo.Tasks
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.WorkflowSteps

  describe "ProjectChannel CDC projection" do
    test "committed row changes produce ProjectChannel events" do
      project = create_project()
      {:ok, task} = Tasks.insert(project, %{title: "Projected task"})

      :ok = subscribe_project(project.id)

      assert {:ok, [%{event: "task_created", project_id: project_id, status: :dispatched}]} =
               project_insert("tasks", task, lsn: {1, 1})

      assert project_id == project.id

      assert_project_broadcast("task_created", %{
        schema_version: 1,
        id: task.id,
        project_id: project.id,
        title: "Projected task"
      })
    end

    test "rolled-back row changes do not dispatch ProjectChannel events" do
      project = create_project()

      :ok = subscribe_project(project.id)

      assert {:error, :aborted} =
               Repo.transaction(fn ->
                 %Task{project_id: project.id, user_id: project.user_id}
                 |> Task.create_changeset(
                   Tasks.assign_default_workflow_attrs(%{title: "Rolled back"}, project.id)
                 )
                 |> Repo.insert!()

                 Repo.rollback(:aborted)
               end)

      refute_project_broadcast("task_created")
    end

    test "rolled-back deletes do not dispatch deleted events" do
      project = create_project()
      {:ok, task} = Tasks.insert(project, %{title: "Delete rollback"})

      :ok = subscribe_project(project.id)

      assert {:error, :aborted} =
               Repo.transaction(fn ->
                 assert {:ok, %Task{}} = Tasks.delete(task)
                 Repo.rollback(:aborted)
               end)

      refute_project_broadcast("task_deleted")
      assert %Task{} = Repo.get(Task, task.id)
    end

    test "representative CRUD payloads update a connected client store without refetches" do
      project = create_project()
      workflow = default_workflow(project.id)
      step = default_step(workflow.id)
      {:ok, task} = Tasks.insert(project, %{title: "Store task"})

      :ok = subscribe_project(project.id)

      store = %{tasks: %{}, steps: %{}, transitions: %{}, sections: %{}}

      {:ok, updated_task} = Tasks.update(task, %{title: "Store task updated"})
      assert {:ok, [%{event: "task_updated"}]} = project_update("tasks", task, updated_task)

      task_payload =
        assert_project_broadcast("task_updated", %{
          schema_version: 1,
          id: task.id,
          title: "Store task updated",
          project_id: project.id,
          workflow_id: task.workflow_id,
          current_step_id: task.current_step_id
        })

      store = put_in(store, [:tasks, task_payload.id], task_payload)
      assert store.tasks[task.id].title == "Store task updated"
      assert store.tasks[task.id].current_step_id == task.current_step_id

      {:ok, updated_step} = WorkflowSteps.update(step, %{goal: "Updated goal"})

      assert {:ok, [%{event: "step_updated"}]} =
               project_update("workflow_steps", step, updated_step)

      step_payload =
        assert_project_broadcast("step_updated", %{
          schema_version: 1,
          id: step.id,
          goal: "Updated goal",
          workflow_id: workflow.id,
          project_id: project.id
        })

      store = put_in(store, [:steps, step_payload.id], step_payload)
      assert store.steps[step.id].goal == "Updated goal"
      assert store.steps[step.id].workflow_id == workflow.id

      {:ok, next_step} = WorkflowSteps.insert(workflow, %{name: "Next", step_order: 2})

      {:ok, transition} =
        StepTransitions.insert(project.user_id, %{
          "project_id" => project.id,
          "from_step_id" => step.id,
          "to_step_id" => next_step.id,
          "label" => "continue"
        })

      assert {:ok, [%{event: "step_transition_created"}]} =
               project_insert("step_transitions", transition)

      transition_payload =
        assert_project_broadcast("step_transition_created", %{
          schema_version: 1,
          id: transition.id,
          from_step_id: step.id,
          to_step_id: next_step.id,
          project_id: project.id
        })

      store = put_in(store, [:transitions, transition_payload.id], transition_payload)
      assert store.transitions[transition.id].label == "continue"

      {:ok, section} =
        TaskSections.insert(task, %{
          "section_type" => "context",
          "content" => "Initial context",
          "section_order" => 1
        })

      {:ok, updated_section} =
        TaskSections.update(section, %{"content" => "Updated context", "done" => true})

      assert {:ok, [%{event: "section_updated"}]} =
               project_update("task_sections", section, updated_section)

      section_payload =
        assert_project_broadcast("section_updated", %{
          schema_version: 1,
          id: section.id,
          task_id: task.id,
          project_id: project.id,
          content: "Updated context",
          done: true
        })

      store = put_in(store, [:sections, section_payload.id], section_payload)
      assert store.sections[section.id].content == "Updated context"
      assert store.sections[section.id].done == true
    end

    test "task dependency changes project complete blocker edges through CDC" do
      project = create_project()
      {:ok, task} = Tasks.insert(project, %{title: "Dependent"})
      {:ok, blocker} = Tasks.insert(project, %{title: "Blocker"})
      {:ok, dependency} = TaskDependencies.add_dependency(task, blocker)

      :ok = subscribe_project(project.id)

      assert {:ok, [%{event: "task_dependency_created"}]} =
               project_insert("task_dependencies", dependency)

      assert_project_broadcast("task_dependency_created", %{
        schema_version: 1,
        id: dependency.id,
        task_id: task.id,
        depends_on_id: blocker.id,
        project_id: project.id
      })

      {:ok, deleted_dependency} = TaskDependencies.remove_dependency(task, blocker)

      assert {:ok, [%{event: "task_dependency_deleted"}]} =
               project_delete("task_dependencies", deleted_dependency)

      assert_project_broadcast("task_dependency_deleted", %{
        schema_version: 1,
        id: dependency.id,
        task_id: task.id,
        depends_on_id: blocker.id,
        project_id: project.id
      })
    end

    test "code ref changes project complete detail and evidence refs through CDC" do
      project = create_project()
      {:ok, task} = Tasks.insert(project, %{title: "Evidence task"})

      {:ok, code_ref} =
        CodeRefs.insert_for_task(task, %{
          path: "lib/sacrum/example.ex",
          line_start: 10,
          line_end: 20,
          name: "Example",
          description: "Initial ref"
        })

      :ok = subscribe_project(project.id)

      assert {:ok, [%{event: "code_ref_created"}]} = project_insert("code_refs", code_ref)

      assert_project_broadcast("code_ref_created", %{
        schema_version: 1,
        id: code_ref.id,
        task_id: task.id,
        section_id: nil,
        project_id: project.id,
        path: "lib/sacrum/example.ex",
        line_start: 10,
        line_end: 20,
        name: "Example",
        description: "Initial ref"
      })

      {:ok, updated_ref} =
        code_ref
        |> CodeRef.changeset(%{name: "Updated Example", line_end: 24})
        |> CodeRefs.update()

      assert {:ok, [%{event: "code_ref_updated"}]} =
               project_update("code_refs", code_ref, updated_ref)

      assert_project_broadcast("code_ref_updated", %{
        schema_version: 1,
        id: code_ref.id,
        task_id: task.id,
        project_id: project.id,
        path: "lib/sacrum/example.ex",
        line_end: 24,
        name: "Updated Example"
      })

      {:ok, deleted_ref} = CodeRefs.delete(updated_ref)

      assert {:ok, [%{event: "code_ref_deleted"}]} = project_delete("code_refs", deleted_ref)

      assert_project_broadcast("code_ref_deleted", %{
        schema_version: 1,
        id: code_ref.id,
        task_id: task.id,
        project_id: project.id,
        path: "lib/sacrum/example.ex",
        line_end: 24,
        name: "Updated Example"
      })
    end

    test "parent changes project an explicit hierarchy delta with before and after parents" do
      project = create_project()
      {:ok, parent} = Tasks.insert(project, %{title: "Parent"})
      {:ok, child} = Tasks.insert(project, %{title: "Child"})

      :ok = subscribe_project(project.id)

      {:ok, updated_child} = Tasks.update(child, %{"parent_id" => parent.id})

      assert {:ok, [%{event: "task_updated"}, %{event: "task_parent_changed"}]} =
               project_update("tasks", child, updated_child)

      assert_project_broadcast("task_updated", %{
        schema_version: 1,
        id: child.id,
        parent_id: parent.id,
        project_id: project.id
      })

      assert_project_broadcast("task_parent_changed", %{
        schema_version: 1,
        task_id: child.id,
        project_id: project.id,
        from_parent_id: nil,
        to_parent_id: parent.id,
        level: child.level
      })
    end

    test "public chat events project through CDC and internal chat events are suppressed" do
      project = create_project()
      {:ok, session} = Sacrum.Accounts.LiveChat.create_session(project.user_id, project.id, %{})

      {:ok, public_event} =
        Sacrum.Accounts.ChatEvents.get_by_type(session, "chat_session_created", :public)

      :ok = subscribe_project(project.id)

      assert {:ok, [%{event: "chat_session_created"}]} =
               project_insert("chat_events", public_event)

      assert_project_broadcast("chat_session_created", %{
        schema_version: 1,
        id: session.id,
        project_id: project.id,
        status: "queued"
      })

      {:ok, internal_event} =
        Sacrum.Accounts.ChatEvents.append(project.user_id, project.id, session.id, %{
          event_type: "runner.tool_trace",
          visibility: :internal,
          public_payload: %{},
          internal_payload: %{"secret" => "hidden"}
        })

      assert {:ok, []} = project_insert("chat_events", internal_event)
      refute_project_broadcast("chat_event_created")
      refute_project_broadcast("runner.tool_trace")
    end
  end

  defp create_project do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Users.insert(%{
        email: "cdc-#{suffix}@example.com",
        username: "cdc#{suffix}",
        password: "password123"
      })

    {:ok, project} = Projects.insert(user, %{name: "CDC Project #{suffix}"})
    project
  end

  defp default_workflow(project_id) do
    Repo.one!(
      from(w in Workflow,
        where: w.project_id == ^project_id and w.is_default == true,
        limit: 1
      )
    )
  end

  defp default_step(workflow_id) do
    Repo.one!(
      from(s in WorkflowStep,
        where: s.workflow_id == ^workflow_id,
        order_by: [asc: s.step_order],
        limit: 1
      )
    )
  end
end
