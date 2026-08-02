defmodule Sacrum.Repo.ArtifactLinksTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.ArtifactLinks
  alias Sacrum.Repo.Artifacts
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.StepExecutions
  alias Sacrum.Repo.TaskSections
  alias Sacrum.Repo.TaskRuns
  alias Sacrum.Repo.Tasks
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Workflows

  defp create_user(prefix \\ "artifact-link") do
    suffix = System.unique_integer([:positive])

    username_prefix =
      prefix
      |> String.replace("-", "_")
      |> String.slice(0, 20)

    {:ok, user} =
      Users.insert(%{
        email: "#{prefix}-#{suffix}@example.com",
        username: "#{username_prefix}_#{suffix}",
        password: "password123"
      })

    user
  end

  defp create_project(user, name \\ "Artifact Link Project") do
    {:ok, project} = Projects.insert(user, %{name: name})
    project
  end

  defp create_artifact(user, project, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          filename: "draft-task.md",
          body: "# Draft task\n\nTask body"
        },
        attrs
      )

    {:ok, artifact} = Artifacts.insert(user.id, project.id, attrs)
    artifact
  end

  defp create_task(project, title \\ "Linked task") do
    {:ok, task} = Tasks.insert(project, %{title: title})
    task
  end

  defp create_section(task, content \\ "Evidence criterion") do
    {:ok, section} =
      TaskSections.insert(task, %{
        section_type: "testing_criterion",
        content: content
      })

    section
  end

  defp create_workflow(_user, project) do
    suffix = System.unique_integer([:positive])

    {:ok, workflow} =
      Workflows.insert(project, %{name: "Artifact Workflow #{suffix}"})

    workflow
  end

  defp create_task_run(user, project, task) do
    {:ok, task_run} = TaskRuns.insert(user.id, project.id, task.id, %{})
    task_run
  end

  defp create_step_execution(user, project, task, workflow, task_run) do
    {:ok, step_execution} =
      StepExecutions.insert(user.id, %{
        project_id: project.id,
        task_id: task.id,
        task_run_id: task_run.id,
        workflow_id: workflow.id,
        step_name: "artifact_link_step",
        status: "completed"
      })

    step_execution
  end

  defp setup_link_scope(_context) do
    user = create_user()
    project = create_project(user)
    task = create_task(project)
    section = create_section(task)
    workflow = create_workflow(user, project)
    task_run = create_task_run(user, project, task)
    step_execution = create_step_execution(user, project, task, workflow, task_run)
    artifact = create_artifact(user, project)

    %{
      user: user,
      project: project,
      task: task,
      section: section,
      workflow: workflow,
      task_run: task_run,
      step_execution: step_execution,
      artifact: artifact
    }
  end

  describe "insert/4" do
    setup [:setup_link_scope]

    test "links artifacts to supported subject resources", %{
      user: user,
      project: project,
      artifact: artifact,
      task: task,
      section: section,
      workflow: workflow,
      task_run: task_run,
      step_execution: step_execution
    } do
      subjects = [
        {"project", project.id},
        {"task", task.id},
        {"task_section", section.id},
        {"workflow", workflow.id},
        {"task_run", task_run.id},
        {"step_execution", step_execution.id}
      ]

      for {subject_type, subject_id} <- subjects do
        assert {:ok, link} =
                 ArtifactLinks.insert(user.id, project.id, artifact.id, %{
                   subject_type: subject_type,
                   subject_id: subject_id
                 })

        assert link.artifact_id == artifact.id
        assert link.subject_type == subject_type
        assert link.subject_id == subject_id
        assert link.project_id == project.id
        assert link.user_id == user.id
      end
    end

    test "rejects project subjects outside the link scope", %{
      user: user,
      project: project,
      artifact: artifact
    } do
      other_project = create_project(user, "Other Project Subject")

      assert {:error, :subject_scope_mismatch} =
               ArtifactLinks.insert(user.id, project.id, artifact.id, %{
                 subject_type: "project",
                 subject_id: other_project.id
               })

      other_user = create_user("other-project-subject-link")
      other_user_project = create_project(other_user, "Other User Project Subject")

      assert {:error, :subject_scope_mismatch} =
               ArtifactLinks.insert(user.id, project.id, artifact.id, %{
                 subject_type: "project",
                 subject_id: other_user_project.id
               })
    end

    test "rejects artifact links whose subject project scope does not match", %{
      user: user,
      project: project,
      artifact: artifact
    } do
      other_project = create_project(user, "Other Subject Project")
      other_project_task = create_task(other_project, "Other project task")

      assert {:error, :subject_scope_mismatch} =
               ArtifactLinks.insert(user.id, project.id, artifact.id, %{
                 subject_type: "task",
                 subject_id: other_project_task.id
               })
    end

    test "rejects workflow, task_run, and step_execution links whose subject scope does not match",
         %{
           user: user,
           project: project,
           artifact: artifact
         } do
      other_project = create_project(user, "Other Execution Subject Project")
      other_task = create_task(other_project, "Other execution task")
      other_workflow = create_workflow(user, other_project)
      other_task_run = create_task_run(user, other_project, other_task)

      other_step_execution =
        create_step_execution(user, other_project, other_task, other_workflow, other_task_run)

      subjects = [
        {"workflow", other_workflow.id},
        {"task_run", other_task_run.id},
        {"step_execution", other_step_execution.id}
      ]

      for {subject_type, subject_id} <- subjects do
        assert {:error, :subject_scope_mismatch} =
                 ArtifactLinks.insert(user.id, project.id, artifact.id, %{
                   subject_type: subject_type,
                   subject_id: subject_id
                 })
      end
    end

    test "rejects workflow, task_run, and step_execution links whose subject user scope does not match",
         %{
           user: user,
           project: project,
           artifact: artifact
         } do
      other_user = create_user("other-execution-subject-link")
      other_project = create_project(other_user, "Other User Execution Subject Project")
      other_task = create_task(other_project, "Other user execution task")
      other_workflow = create_workflow(other_user, other_project)
      other_task_run = create_task_run(other_user, other_project, other_task)

      other_step_execution =
        create_step_execution(
          other_user,
          other_project,
          other_task,
          other_workflow,
          other_task_run
        )

      subjects = [
        {"workflow", other_workflow.id},
        {"task_run", other_task_run.id},
        {"step_execution", other_step_execution.id}
      ]

      for {subject_type, subject_id} <- subjects do
        assert {:error, :subject_scope_mismatch} =
                 ArtifactLinks.insert(user.id, project.id, artifact.id, %{
                   subject_type: subject_type,
                   subject_id: subject_id
                 })
      end
    end

    test "rejects artifact links whose artifact user scope does not match", %{
      user: user,
      project: project,
      task: task
    } do
      other_user = create_user("other-artifact-link")
      other_project = create_project(other_user, "Other Artifact Project")
      other_user_artifact = create_artifact(other_user, other_project)

      assert {:error, :artifact_scope_mismatch} =
               ArtifactLinks.insert(user.id, project.id, other_user_artifact.id, %{
                 subject_type: "task",
                 subject_id: task.id
               })
    end

    test "enforces logical name uniqueness within a subject without changing the existing link",
         %{
           user: user,
           project: project,
           task: task,
           artifact: artifact
         } do
      {:ok, existing_link} =
        ArtifactLinks.insert(user.id, project.id, artifact.id, %{
          subject_type: "task",
          subject_id: task.id,
          logical_name: "implementation_plan"
        })

      competing_artifact = create_artifact(user, project, %{filename: "competing-plan.md"})

      assert {:error, changeset} =
               ArtifactLinks.insert(user.id, project.id, competing_artifact.id, %{
                 subject_type: "task",
                 subject_id: task.id,
                 logical_name: "implementation_plan"
               })

      assert %{logical_name: ["has already been taken"]} = errors_on(changeset)

      assert [persisted_link] =
               ArtifactLinks.list_by_subject(user.id, project.id, "task", task.id)

      assert persisted_link.id == existing_link.id
      assert persisted_link.artifact_id == artifact.id
      assert persisted_link.logical_name == "implementation_plan"
      assert {:ok, persisted_artifact} = Artifacts.get(competing_artifact.id)
      assert persisted_artifact.filename == "competing-plan.md"
    end

    test "allows a logical name to be reused on different subjects", %{
      user: user,
      project: project,
      task: task,
      artifact: artifact
    } do
      other_task = create_task(project, "Other linked task")

      for subject_id <- [task.id, other_task.id] do
        assert {:ok, link} =
                 ArtifactLinks.insert(user.id, project.id, artifact.id, %{
                   subject_type: "task",
                   subject_id: subject_id,
                   logical_name: "implementation_plan"
                 })

        assert link.logical_name == "implementation_plan"
      end
    end
  end

  describe "scoped reads" do
    setup [:setup_link_scope]

    test "lists named StepExecution identities in bulk and keeps them TaskRun-scoped", %{
      user: user,
      project: project,
      task: task,
      workflow: workflow,
      task_run: task_run,
      step_execution: first_execution,
      artifact: first_artifact
    } do
      second_execution = create_step_execution(user, project, task, workflow, task_run)
      other_task_run = create_task_run(user, project, task)
      other_execution = create_step_execution(user, project, task, workflow, other_task_run)
      second_artifact = create_artifact(user, project, %{filename: "second.md"})
      other_artifact = create_artifact(user, project, %{filename: "other.md"})

      {:ok, _first_link} =
        ArtifactLinks.insert(user.id, project.id, first_artifact.id, %{
          subject_type: "step_execution",
          subject_id: first_execution.id,
          logical_name: "older"
        })

      {:ok, _second_link} =
        ArtifactLinks.insert(user.id, project.id, second_artifact.id, %{
          subject_type: "step_execution",
          subject_id: second_execution.id,
          logical_name: "newer"
        })

      {:ok, _unnamed_link} =
        ArtifactLinks.insert(user.id, project.id, first_artifact.id, %{
          subject_type: "step_execution",
          subject_id: second_execution.id
        })

      {:ok, _other_link} =
        ArtifactLinks.insert(user.id, project.id, other_artifact.id, %{
          subject_type: "step_execution",
          subject_id: other_execution.id,
          logical_name: "other_run"
        })

      identities =
        ArtifactLinks.list_step_execution_identities(
          user.id,
          project.id,
          task.id,
          task_run.id,
          [first_execution.id, second_execution.id, other_execution.id]
        )

      assert identities == [
               %{
                 step_execution_id: first_execution.id,
                 artifact_id: first_artifact.id,
                 logical_name: "older"
               },
               %{
                 step_execution_id: second_execution.id,
                 artifact_id: second_artifact.id,
                 logical_name: "newer"
               }
             ]

      refute Enum.any?(identities, &(&1.logical_name == "other_run"))
      refute Enum.any?(identities, &Map.has_key?(&1, :body))
    end

    test "lists links by subject without leaking links outside project or user scope", %{
      user: user,
      project: project,
      task: task,
      artifact: artifact,
      workflow: workflow,
      task_run: task_run,
      step_execution: step_execution
    } do
      other_project = create_project(user, "Other Link Project")
      other_project_task = create_task(other_project, "Other linked task")

      other_project_artifact =
        create_artifact(user, other_project, %{filename: "other-project-plan.md"})

      other_user = create_user("other-subject-link")
      other_user_project = create_project(other_user, "Other User Project")
      other_user_task = create_task(other_user_project, "Other user task")
      other_user_artifact = create_artifact(other_user, other_user_project)

      {:ok, link} =
        ArtifactLinks.insert(user.id, project.id, artifact.id, %{
          subject_type: "task",
          subject_id: task.id
        })

      {:ok, other_project_link} =
        ArtifactLinks.insert(user.id, other_project.id, other_project_artifact.id, %{
          subject_type: "task",
          subject_id: other_project_task.id
        })

      {:ok, other_user_link} =
        ArtifactLinks.insert(other_user.id, other_user_project.id, other_user_artifact.id, %{
          subject_type: "task",
          subject_id: other_user_task.id
        })

      listed_ids =
        user.id
        |> ArtifactLinks.list_by_subject(project.id, "task", task.id)
        |> Enum.map(& &1.id)

      assert link.id in listed_ids
      refute other_project_link.id in listed_ids
      refute other_user_link.id in listed_ids

      for {subject_type, subject_id} <- [
            {"workflow", workflow.id},
            {"task_run", task_run.id},
            {"step_execution", step_execution.id}
          ] do
        {:ok, scoped_link} =
          ArtifactLinks.insert(user.id, project.id, artifact.id, %{
            subject_type: subject_type,
            subject_id: subject_id
          })

        listed_ids =
          user.id
          |> ArtifactLinks.list_by_subject(project.id, subject_type, subject_id)
          |> Enum.map(& &1.id)

        assert listed_ids == [scoped_link.id]
      end
    end

    test "lists links by artifact without leaking links outside project or user scope", %{
      user: user,
      project: project,
      artifact: artifact,
      task: task,
      section: section,
      workflow: workflow,
      task_run: task_run,
      step_execution: step_execution
    } do
      other_project = create_project(user, "Other Artifact Link Project")

      other_project_artifact =
        create_artifact(user, other_project, %{filename: "other-project-artifact.md"})

      other_project_task = create_task(other_project, "Other artifact task")

      {:ok, task_link} =
        ArtifactLinks.insert(user.id, project.id, artifact.id, %{
          subject_type: "task",
          subject_id: task.id
        })

      {:ok, section_link} =
        ArtifactLinks.insert(user.id, project.id, artifact.id, %{
          subject_type: "task_section",
          subject_id: section.id
        })

      {:ok, workflow_link} =
        ArtifactLinks.insert(user.id, project.id, artifact.id, %{
          subject_type: "workflow",
          subject_id: workflow.id
        })

      {:ok, task_run_link} =
        ArtifactLinks.insert(user.id, project.id, artifact.id, %{
          subject_type: "task_run",
          subject_id: task_run.id
        })

      {:ok, step_execution_link} =
        ArtifactLinks.insert(user.id, project.id, artifact.id, %{
          subject_type: "step_execution",
          subject_id: step_execution.id
        })

      {:ok, other_project_link} =
        ArtifactLinks.insert(user.id, other_project.id, other_project_artifact.id, %{
          subject_type: "task",
          subject_id: other_project_task.id
        })

      listed_ids =
        user.id
        |> ArtifactLinks.list_by_artifact(project.id, artifact.id)
        |> Enum.map(& &1.id)

      assert task_link.id in listed_ids
      assert section_link.id in listed_ids
      assert workflow_link.id in listed_ids
      assert task_run_link.id in listed_ids
      assert step_execution_link.id in listed_ids
      refute other_project_link.id in listed_ids
    end
  end
end
