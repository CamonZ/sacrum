defmodule Sacrum.Chat.DirectTrackerOperationResolverTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts
  alias Sacrum.Chat.DirectTrackerOperationResolver
  alias Sacrum.Repo.Schemas.{Task, Workflow, WorkflowStep}
  alias Sacrum.Repo.Users

  defp create_user(label) do
    suffix = System.unique_integer([:positive])
    username_label = label |> String.replace(~r/[^a-zA-Z0-9_]/, "_") |> String.slice(0, 8)

    {:ok, user} =
      Users.insert(%{
        email: "direct-tracker-#{label}-#{suffix}@example.com",
        username: "dt_#{username_label}_#{suffix}",
        password: "password123"
      })

    user
  end

  defp create_project(user, name) do
    {:ok, project} = Accounts.Projects.insert(user.id, %{name: name})
    project
  end

  defp create_workflow(user, project, attrs) do
    attrs = Map.merge(%{name: "Workflow #{System.unique_integer([:positive])}"}, attrs)
    {:ok, workflow} = Accounts.Workflows.insert(user.id, project.id, attrs)
    workflow
  end

  defp create_step(_user, workflow, attrs) do
    attrs =
      Map.merge(
        %{
          name: "Step #{System.unique_integer([:positive])}",
          step_order: System.unique_integer([:positive])
        },
        attrs
      )

    {:ok, step} = Accounts.WorkflowSteps.insert(workflow, attrs)
    step
  end

  defp create_task(user, project, workflow, step, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          title: "Task #{System.unique_integer([:positive])}",
          level: "ticket",
          workflow_id: workflow.id,
          current_step_id: step.id
        },
        attrs
      )

    {:ok, task} = Accounts.Tasks.insert(user.id, project.id, attrs)
    task
  end

  defp create_section(task, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{"section_type" => "goal", "content" => "Resolve direct tracker operation context."},
        attrs
      )

    attrs =
      attrs
      |> Map.put("task_id", task.id)
      |> Map.put("project_id", task.project_id)

    {:ok, section} = Accounts.Sections.insert(task.user_id, attrs)
    section
  end

  defp create_chat_session(user, project, attrs \\ %{}) do
    {:ok, session} = Accounts.ChatSessions.insert(user.id, project.id, attrs)
    session
  end

  defp scoped_context(user, project, session, overrides \\ %{}) do
    Map.merge(
      %{
        user_id: user.id,
        project_id: project.id,
        chat_session_id: session.id
      },
      overrides
    )
  end

  describe "resolve_directive/2" do
    test "resolves the active workflow step from server-owned chat context and ignores a model-supplied step id" do
      user = create_user("active-context")
      project = create_project(user, "Active Context")
      workflow = create_workflow(user, project, %{name: "Implementation"})
      intended_step = create_step(user, workflow, %{name: "Implement"})
      misleading_step = create_step(user, workflow, %{name: "Review"})
      task = create_task(user, project, workflow, intended_step)
      session = create_chat_session(user, project)

      directive = %{
        "action" => "update_workflow_step",
        "workflow_ref" => workflow.id,
        "step_ref" => misleading_step.id,
        "fields" => %{"prompt" => "Use the model-selected step."}
      }

      assert {:ok, resolved} =
               DirectTrackerOperationResolver.resolve_directive(
                 directive,
                 scoped_context(user, project, session, %{
                   active_object: %{type: "workflow_step", id: intended_step.id},
                   active_task_id: task.id
                 })
               )

      intended_step_id = intended_step.id
      workflow_id = workflow.id
      task_id = task.id

      assert %WorkflowStep{id: ^intended_step_id} = resolved.targets.workflow_step
      assert %Workflow{id: ^workflow_id} = resolved.targets.workflow
      assert %Task{id: ^task_id} = resolved.targets.task
      assert resolved.scope.user_id == user.id
      assert resolved.scope.project_id == project.id
      assert resolved.scope.chat_session_id == session.id
    end

    test "rejects direct operation targets outside the AgentServer user and project scope" do
      owner = create_user("owner")
      owner_project = create_project(owner, "Owner Project")
      owner_workflow = create_workflow(owner, owner_project, %{name: "Owner Workflow"})
      owner_step = create_step(owner, owner_workflow, %{name: "Owner Step"})
      owner_task = create_task(owner, owner_project, owner_workflow, owner_step)
      session = create_chat_session(owner, owner_project)

      other = create_user("other")
      other_project = create_project(other, "Other Project")
      other_workflow = create_workflow(other, other_project, %{name: "Other Workflow"})
      other_step = create_step(other, other_workflow, %{name: "Other Step"})
      other_task = create_task(other, other_project, other_workflow, other_step)

      context = scoped_context(owner, owner_project, session)

      scoped_failures = [
        %{
          directive: %{"action" => "show_task", "task_ref" => other_task.id},
          expected_target: {:task, other_task.id}
        },
        %{
          directive: %{"action" => "read_task_sections", "task_ref" => other_task.id},
          expected_target: {:task, other_task.id}
        },
        %{
          directive: %{
            "action" => "move_task_to_workflow_step",
            "task_ref" => owner_task.id,
            "workflow_ref" => other_workflow.id,
            "step_ref" => other_step.id
          },
          expected_target: {:workflow, other_workflow.id}
        },
        %{
          directive: %{
            "action" => "update_workflow_step",
            "workflow_ref" => owner_workflow.id,
            "step_ref" => other_step.id,
            "fields" => %{"prompt" => "Out of scope"}
          },
          expected_target: {:workflow_step, other_step.id}
        }
      ]

      for %{directive: directive, expected_target: expected_target} <- scoped_failures do
        assert {:error, {:unauthorized_target, ^expected_target}} =
                 DirectTrackerOperationResolver.resolve_directive(directive, context)
      end
    end

    test "rejects server-owned scope and permission fields supplied by the model" do
      user = create_user("scope-fields")
      project = create_project(user, "Scope Fields")
      workflow = create_workflow(user, project, %{name: "Scope Workflow"})
      step = create_step(user, workflow, %{name: "Scope Step"})
      task = create_task(user, project, workflow, step)
      session = create_chat_session(user, project)

      directive = %{
        "action" => "show_task",
        "task_ref" => task.id,
        "user_id" => Ecto.UUID.generate(),
        "project_id" => Ecto.UUID.generate(),
        "object_id" => Ecto.UUID.generate(),
        "permission" => "admin",
        "permissions" => ["tracker:write", "admin"]
      }

      assert {:error, {:forbidden_model_scope_fields, fields}} =
               DirectTrackerOperationResolver.resolve_directive(
                 directive,
                 scoped_context(user, project, session)
               )

      assert Enum.sort(fields) == ~w(object_id permission permissions project_id user_id)
    end

    test "returns ambiguous target when a short task ref matches multiple scoped tasks" do
      user = create_user("ambiguous-task")
      project = create_project(user, "Ambiguous Task")
      workflow = create_workflow(user, project, %{name: "Ambiguous Workflow"})
      step = create_step(user, workflow, %{name: "Ambiguous Step"})
      session = create_chat_session(user, project)

      [first_task, second_task] =
        Enum.map(
          [
            "12345678-0000-0000-0000-000000000001",
            "12345678-0000-0000-0000-000000000002"
          ],
          fn id ->
            task = create_task(user, project, workflow, step)

            {_count, nil} =
              Sacrum.Repo.update_all(from(t in Task, where: t.id == ^task.id), set: [id: id])

            %{task | id: id}
          end
        )

      assert {:error, {:ambiguous, candidates}} =
               DirectTrackerOperationResolver.resolve_directive(
                 %{"action" => "show_task", "task_ref" => "12345678"},
                 scoped_context(user, project, session)
               )

      assert Enum.sort(candidates) == Enum.sort([first_task.id, second_task.id])
    end
  end

  describe "resolve_target_reference/2" do
    test "rejects chat-visible task, section, workflow, and workflow step refs outside the AgentServer scope" do
      owner = create_user("reference-owner")
      owner_project = create_project(owner, "Reference Owner")
      session = create_chat_session(owner, owner_project)

      other = create_user("reference-other")
      other_project = create_project(other, "Reference Other")
      other_workflow = create_workflow(other, other_project, %{name: "Other Workflow"})
      other_step = create_step(other, other_workflow, %{name: "Other Step"})
      other_task = create_task(other, other_project, other_workflow, other_step)
      other_section = create_section(other_task)

      context = scoped_context(owner, owner_project, session)

      scoped_references = [
        {:task, other_task.id},
        {:section, other_section.id},
        {:workflow, other_workflow.id},
        {:workflow_step, other_step.id}
      ]

      for {target_type, target_ref} <- scoped_references do
        assert {:error, {:unauthorized_target, {^target_type, ^target_ref}}} =
                 DirectTrackerOperationResolver.resolve_target_reference(
                   %{type: target_type, ref: target_ref},
                   context
                 )
      end
    end
  end
end
