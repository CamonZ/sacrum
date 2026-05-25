defmodule Sacrum.Chat.DirectTrackerOperationExecutorTest do
  use Sacrum.DataCase, async: true

  import Ecto.Query

  alias Sacrum.Accounts
  alias Sacrum.Chat.DirectTrackerOperationExecutor
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.TaskDependency
  alias Sacrum.Repo.Users

  defp create_user(label) do
    suffix = System.unique_integer([:positive])
    username_label = label |> String.replace(~r/[^a-zA-Z0-9_]/, "_") |> String.slice(0, 8)

    {:ok, user} =
      Users.insert(%{
        email: "direct-executor-#{label}-#{suffix}@example.com",
        username: "dex_#{username_label}_#{suffix}",
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

  defp create_step(workflow, attrs) do
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
          level: "task",
          workflow_id: workflow.id,
          current_step_id: step.id
        },
        attrs
      )

    {:ok, task} = Accounts.Tasks.insert(user.id, project.id, attrs)
    task
  end

  defp tracker_context(label, attrs \\ %{}) do
    user = create_user(label)
    project = create_project(user, Map.get(attrs, :project_name, "Direct Executor Project"))
    workflow = create_workflow(user, project, Map.get(attrs, :workflow_attrs, %{}))
    step = create_step(workflow, Map.get(attrs, :step_attrs, %{}))
    task = create_task(user, project, workflow, step, Map.get(attrs, :task_attrs, %{}))

    %{user: user, project: project, workflow: workflow, step: step, task: task}
  end

  defp resolved_operation(action, targets, arguments \\ %{}) do
    %{
      action: action,
      arguments: arguments,
      targets: targets
    }
  end

  defp dependency_count(task) do
    Repo.one(from d in TaskDependency, where: d.task_id == ^task.id, select: count(d.id))
  end

  describe "execute/1 update_task_fields" do
    test "does not accept or return removed review metadata fields" do
      %{user: user, task: task} = tracker_context("taskfields")

      operation =
        resolved_operation("update_task_fields", %{task: task}, %{
          "fields" => %{
            "title" => "Updated title",
            "needs_human_review" => true,
            "review_comment" => "please review",
            "revision_feedback" => "fix tests"
          }
        })

      assert {:ok, %{action: "update_task_fields", task: result}} =
               DirectTrackerOperationExecutor.execute(operation)

      assert result.title == "Updated title"
      refute Map.has_key?(result, :needs_human_review)
      refute Map.has_key?(result, :review_comment)
      refute Map.has_key?(result, :revision_feedback)

      assert {:ok, updated_task} = Accounts.Tasks.find(user.id, task.id)
      assert updated_task.title == "Updated title"
      refute Map.has_key?(updated_task, :needs_human_review)
      refute Map.has_key?(updated_task, :review_comment)
      refute Map.has_key?(updated_task, :revision_feedback)
    end
  end

  describe "execute/1 update_workflow_step" do
    test "updates the server-resolved workflow step through Accounts.WorkflowSteps.update/2" do
      %{user: user, workflow: workflow, step: step, task: task} =
        tracker_context("step", %{
          step_attrs: %{
            name: "Implementation",
            prompt: "Old prompt",
            goal: "Old goal",
            agent_config: %{"model" => "old-model"}
          }
        })

      operation =
        resolved_operation(
          "update_workflow_step",
          %{task: task, workflow: workflow, workflow_step: step},
          %{
            "fields" => %{
              "prompt" => "Use the resolved Accounts step.",
              "goal" => "Update the app-owned step directly.",
              "agent_config" => %{"model" => "gpt-5.1", "reasoning_effort" => "high"}
            }
          }
        )

      assert {:ok, result} = DirectTrackerOperationExecutor.execute(operation)

      assert %{
               action: "update_workflow_step",
               workflow_step: %{
                 id: step_id,
                 prompt: "Use the resolved Accounts step.",
                 goal: "Update the app-owned step directly.",
                 agent_config: %{"model" => "gpt-5.1", "reasoning_effort" => "high"}
               }
             } = result

      assert step_id == step.id

      assert {:ok, updated_step} =
               Accounts.WorkflowSteps.get_by(user.id, conditions: [id: step.id])

      assert updated_step.prompt == "Use the resolved Accounts step."
      assert updated_step.goal == "Update the app-owned step directly."
      assert updated_step.agent_config == %{"model" => "gpt-5.1", "reasoning_effort" => "high"}

      assert [] =
               Repo.all(
                 from artifact in Sacrum.Repo.Schemas.Artifact,
                   where: artifact.user_id == ^user.id
               )
    end
  end

  describe "execute/1 upsert_task_section" do
    test "adds a checklist item through Accounts.Sections.insert/2 and returns durable section details" do
      %{user: user, project: project, task: task} = tracker_context("checklist")

      operation =
        resolved_operation(
          "upsert_task_section",
          %{task: task},
          %{
            "section_type" => "checklist_item",
            "content" => "Confirm direct tracker executor writes through Accounts.Sections.",
            "done" => false
          }
        )

      assert {:ok, result} = DirectTrackerOperationExecutor.execute(operation)

      assert %{
               action: "upsert_task_section",
               section: %{
                 id: section_id,
                 section_type: "checklist_item",
                 section_order: section_order,
                 content: "Confirm direct tracker executor writes through Accounts.Sections."
               }
             } = result

      assert is_binary(section_id)
      assert is_integer(section_order)

      assert {:ok, section} = Accounts.Sections.get_by(user.id, conditions: [id: section_id])
      assert section.task_id == task.id
      assert section.project_id == project.id
      assert section.section_type == "checklist_item"
      assert section.section_order == section_order
      refute section.done
    end

    test "updates an existing resolved section through Accounts.Sections.update/2" do
      %{user: user, project: project, task: task} = tracker_context("section")

      {:ok, section} =
        Accounts.Sections.insert(user.id, %{
          "task_id" => task.id,
          "project_id" => project.id,
          "section_type" => "checklist_item",
          "section_order" => 4,
          "content" => "Old section content",
          "done" => false
        })

      operation =
        resolved_operation(
          "upsert_task_section",
          %{task: task, task_section: section},
          %{
            "section_type" => "checklist_item",
            "content" => "Updated section content",
            "done" => true
          }
        )

      assert {:ok, result} = DirectTrackerOperationExecutor.execute(operation)

      assert %{
               action: "upsert_task_section",
               section: %{
                 id: section_id,
                 section_type: "checklist_item",
                 section_order: 4,
                 content: "Updated section content",
                 done: true
               }
             } = result

      assert section_id == section.id

      assert {:ok, updated_section} =
               Accounts.Sections.get_by(user.id, conditions: [id: section.id])

      assert updated_section.content == "Updated section content"
      assert updated_section.section_order == 4
      assert updated_section.done
    end
  end

  describe "execute/1 task dependency changes" do
    test "adds and removes dependencies through the existing task dependency services" do
      %{workflow: workflow, step: step, task: task, user: user, project: project} =
        tracker_context("deps", %{task_attrs: %{title: "Blocked task"}})

      blocker = create_task(user, project, workflow, step, %{title: "Blocking task"})

      add_operation =
        resolved_operation("add_task_dependency", %{task: task, depends_on: blocker})

      assert {:ok,
              %{
                action: "add_task_dependency",
                dependency: %{
                  id: dependency_id,
                  task_id: task_id,
                  depends_on_id: depends_on_id
                }
              }} = DirectTrackerOperationExecutor.execute(add_operation)

      assert is_binary(dependency_id)
      assert task_id == task.id
      assert depends_on_id == blocker.id
      assert dependency_count(task) == 1

      remove_operation =
        resolved_operation("remove_task_dependency", %{task: task, depends_on: blocker})

      assert {:ok,
              %{
                action: "remove_task_dependency",
                dependency: %{
                  id: ^dependency_id,
                  task_id: ^task_id,
                  depends_on_id: ^depends_on_id
                }
              }} = DirectTrackerOperationExecutor.execute(remove_operation)

      assert dependency_count(task) == 0
    end

    test "surfaces domain validation errors without partial dependency mutations" do
      %{task: task, workflow: workflow, step: step, user: user, project: project} =
        tracker_context("validation", %{project_name: "Validation Project"})

      blocker = create_task(user, project, workflow, step)

      %{
        task: other_task
      } = tracker_context("validation-other", %{project_name: "Other Project"})

      assert {:error, :self_dependency} =
               DirectTrackerOperationExecutor.execute(
                 resolved_operation("add_task_dependency", %{task: task, depends_on: task})
               )

      assert dependency_count(task) == 0

      assert {:error, :different_projects} =
               DirectTrackerOperationExecutor.execute(
                 resolved_operation("add_task_dependency", %{task: task, depends_on: other_task})
               )

      assert dependency_count(task) == 0

      assert {:ok, _dependency} =
               DirectTrackerOperationExecutor.execute(
                 resolved_operation("add_task_dependency", %{task: task, depends_on: blocker})
               )

      assert dependency_count(task) == 1

      assert {:error, :circular_dependency} =
               DirectTrackerOperationExecutor.execute(
                 resolved_operation("add_task_dependency", %{task: blocker, depends_on: task})
               )

      assert dependency_count(task) == 1
      assert dependency_count(blocker) == 0
    end
  end
end
