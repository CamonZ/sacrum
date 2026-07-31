defmodule Sacrum.Accounts.ArtifactsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.Artifacts
  alias Sacrum.Accounts.Projects
  alias Sacrum.Accounts.Tasks
  alias Sacrum.Repo
  alias Sacrum.Repo.ArtifactLinks
  alias Sacrum.Repo.Artifacts, as: ArtifactsRepo
  alias Sacrum.Repo.Schemas.{Artifact, ArtifactLink}
  alias Sacrum.Repo.StepExecutions
  alias Sacrum.Repo.TaskSections
  alias Sacrum.Repo.TaskRuns
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Workflows

  defp create_user(prefix \\ "account-artifact") do
    suffix = System.unique_integer([:positive])
    username_prefix = String.replace(prefix, "-", "_")

    {:ok, user} =
      Users.insert(%{
        email: "#{prefix}-#{suffix}@example.com",
        username: "#{username_prefix}_#{suffix}",
        password: "password123"
      })

    user
  end

  defp create_project(user, name \\ "Account Artifact Project") do
    {:ok, project} = Projects.insert(user.id, %{name: name})
    project
  end

  defp create_task(user, project, title \\ "Artifact subject task") do
    {:ok, task} = Tasks.insert(user.id, project.id, %{title: title})
    task
  end

  defp create_section(task, content \\ "Artifact evidence") do
    {:ok, section} =
      TaskSections.insert(task, %{
        section_type: "testing_criterion",
        content: content
      })

    section
  end

  defp create_workflow(project) do
    suffix = System.unique_integer([:positive])
    {:ok, workflow} = Workflows.insert(project, %{name: "Artifact workflow #{suffix}"})
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
        step_name: "artifact_step",
        status: "completed"
      })

    step_execution
  end

  defp create_artifact(user, project, attrs) do
    attrs =
      Map.merge(
        %{
          filename: "implementation-plan.md",
          body: "# Implementation plan\n\nPersist through the artifact domain service."
        },
        attrs
      )

    {:ok, artifact} = ArtifactsRepo.insert(user.id, project.id, attrs)
    artifact
  end

  defp link_artifact(user, project, artifact, subject_type, subject_id) do
    {:ok, link} =
      ArtifactLinks.insert(user.id, project.id, artifact.id, %{
        subject_type: subject_type,
        subject_id: subject_id
      })

    link
  end

  defp artifact_attrs(attrs \\ %{}) do
    Map.merge(
      %{
        filename: "scoped-artifact.md",
        body: "# Scoped artifact\n\nCreated and linked below the API layer."
      },
      attrs
    )
  end

  defp link_attrs(subject_type, subject_id, attrs \\ %{}) do
    Map.merge(
      %{
        subject_type: subject_type,
        subject_id: subject_id
      },
      attrs
    )
  end

  defp conversation_metadata(overrides \\ %{}) do
    Map.merge(
      %{
        "version" => 1,
        "content_kind" => "conversation",
        "format" => "jsonl",
        "origin" => "harness",
        "presentation" => "raw",
        "extensions" => %{"harness" => %{"conversation_id" => "conv-123"}}
      },
      overrides
    )
  end

  defp setup_artifact_scope(_context) do
    user = create_user()
    project = create_project(user)
    task = create_task(user, project)
    section = create_section(task)

    %{
      user: user,
      project: project,
      task: task,
      section: section
    }
  end

  describe "get/2" do
    setup [:setup_artifact_scope]

    test "returns an artifact in the caller's ownership scope", %{user: user, project: project} do
      artifact = create_artifact(user, project, %{filename: "readme.md", body: "Artifact body"})

      assert {:ok, found_artifact} = Artifacts.get(user.id, artifact.id)
      assert found_artifact.id == artifact.id
      assert found_artifact.user_id == user.id
      assert found_artifact.project_id == project.id
      assert found_artifact.filename == "readme.md"
      assert found_artifact.body == "Artifact body"
    end

    test "returns not found for a missing artifact", %{user: user} do
      assert {:error, :not_found} = Artifacts.get(user.id, Ecto.UUID.generate())
    end

    test "does not return another user's artifact", %{user: user, project: project} do
      artifact = create_artifact(user, project, %{})
      other_user = create_user("other-artifact-reader")

      assert {:error, :not_found} = Artifacts.get(other_user.id, artifact.id)
    end
  end

  describe "create_and_link/4" do
    setup [:setup_artifact_scope]

    test "creates an artifact and link through repo-backed persistence", %{
      user: user,
      project: project,
      task: task
    } do
      assert Repo.aggregate(Artifact, :count) == 0
      assert Repo.aggregate(ArtifactLink, :count) == 0

      assert {:ok, %{artifact: artifact, link: link}} =
               Artifacts.create_and_link(
                 user.id,
                 project.id,
                 artifact_attrs(%{filename: "task-plan.json", body: ~s({"status":"ready"})}),
                 link_attrs("task", task.id)
               )

      assert artifact.user_id == user.id
      assert artifact.project_id == project.id
      assert artifact.filename == "task-plan.json"
      assert artifact.body == ~s({"status":"ready"})

      assert link.user_id == user.id
      assert link.project_id == project.id
      assert link.artifact_id == artifact.id
      assert link.subject_type == "task"
      assert link.subject_id == task.id

      assert Repo.aggregate(Artifact, :count) == 1
      assert Repo.aggregate(ArtifactLink, :count) == 1
    end

    test "creates one artifact link for every supported subject", %{
      user: user,
      project: project,
      task: task,
      section: section
    } do
      workflow = create_workflow(project)
      task_run = create_task_run(user, project, task)
      step_execution = create_step_execution(user, project, task, workflow, task_run)

      subjects = [
        {"project", project.id},
        {"task", task.id},
        {"task_section", section.id},
        {"workflow", workflow.id},
        {"task_run", task_run.id},
        {"step_execution", step_execution.id}
      ]

      for {subject_type, subject_id} <- subjects do
        assert {:ok, %{artifact: artifact, link: link}} =
                 Artifacts.create_and_link(
                   user.id,
                   project.id,
                   artifact_attrs(%{filename: "#{subject_type}.md"}),
                   link_attrs(subject_type, subject_id)
                 )

        assert artifact.user_id == user.id
        assert artifact.project_id == project.id
        assert link.artifact_id == artifact.id
        assert link.subject_type == subject_type
        assert link.subject_id == subject_id
      end

      assert Repo.aggregate(Artifact, :count) == length(subjects)
      assert Repo.aggregate(ArtifactLink, :count) == length(subjects)
    end

    test "transactionally creates and links a file to its project", %{
      user: user,
      project: project
    } do
      assert {:ok, %{artifact: artifact, link: link}} =
               Artifacts.create_and_link(
                 user.id,
                 project.id,
                 artifact_attrs(%{filename: "project-overview.md"}),
                 link_attrs("project", project.id)
               )

      assert artifact.filename == "project-overview.md"
      assert link.artifact_id == artifact.id
      assert link.subject_type == "project"
      assert link.subject_id == project.id

      assert [listed_artifact] =
               Artifacts.list_for_subject(user.id, project.id, "project", project.id)

      assert listed_artifact.id == artifact.id
      assert listed_artifact.body == artifact.body
    end

    test "rolls back the file when the project subject is invalid", %{
      user: user,
      project: project
    } do
      assert {:error, :subject_scope_mismatch} =
               Artifacts.create_and_link(
                 user.id,
                 project.id,
                 artifact_attrs(),
                 link_attrs("project", Ecto.UUID.generate())
               )

      assert Repo.aggregate(Artifact, :count) == 0
      assert Repo.aggregate(ArtifactLink, :count) == 0
    end

    test "rejects malformed or unsupported destinations atomically", %{
      user: user,
      project: project
    } do
      assert {:error, changeset} =
               Artifacts.create_and_link(
                 user.id,
                 project.id,
                 artifact_attrs(),
                 %{subject_type: "task"}
               )

      assert %{subject_id: ["can't be blank"]} = errors_on(changeset)
      assert Repo.aggregate(Artifact, :count) == 0
      assert Repo.aggregate(ArtifactLink, :count) == 0

      assert {:error, changeset} =
               Artifacts.create_and_link(
                 user.id,
                 project.id,
                 artifact_attrs(),
                 link_attrs("unsupported", Ecto.UUID.generate())
               )

      assert %{subject_type: ["is invalid"]} = errors_on(changeset)
      assert Repo.aggregate(Artifact, :count) == 0
      assert Repo.aggregate(ArtifactLink, :count) == 0
    end

    test "rejects linking a new artifact to a subject in another project", %{
      user: user,
      project: project
    } do
      other_project = create_project(user, "Other Account Artifact Project")
      other_project_task = create_task(user, other_project, "Other project task")

      assert {:error, :subject_scope_mismatch} =
               Artifacts.create_and_link(
                 user.id,
                 project.id,
                 artifact_attrs(),
                 link_attrs("task", other_project_task.id)
               )

      assert Repo.aggregate(Artifact, :count) == 0
      assert Repo.aggregate(ArtifactLink, :count) == 0
    end

    test "rejects linking a new artifact to a subject owned by another user", %{
      user: user,
      project: project
    } do
      other_user = create_user("other-account-artifact")
      other_project = create_project(other_user, "Other User Account Artifact Project")
      other_user_task = create_task(other_user, other_project, "Other user task")

      assert {:error, :subject_scope_mismatch} =
               Artifacts.create_and_link(
                 user.id,
                 project.id,
                 artifact_attrs(),
                 link_attrs("task", other_user_task.id)
               )

      assert Repo.aggregate(Artifact, :count) == 0
      assert Repo.aggregate(ArtifactLink, :count) == 0
    end
  end

  describe "update/4" do
    setup [:setup_artifact_scope]

    test "updates filename and body independently", %{user: user, project: project} do
      artifact = create_artifact(user, project, %{})

      assert {:ok, renamed_artifact} =
               Artifacts.update(user.id, artifact.id, %{filename: "renamed.md"})

      assert renamed_artifact.filename == "renamed.md"
      assert renamed_artifact.body == artifact.body

      assert {:ok, edited_artifact} =
               Artifacts.update(user.id, artifact.id, %{body: "# Edited body"})

      assert edited_artifact.filename == "renamed.md"
      assert edited_artifact.body == "# Edited body"
    end

    test "validates metadata updates and preserves the prior attachment on failure", %{
      user: user,
      project: project
    } do
      assert {:ok, %{artifact: artifact}} =
               Artifacts.create_and_link(
                 user.id,
                 project.id,
                 artifact_attrs(),
                 link_attrs("project", project.id)
               )

      metadata = conversation_metadata()

      assert {:ok, updated_artifact} =
               Artifacts.update(user.id, artifact.id, %{}, %{
                 metadata: metadata
               })

      assert updated_artifact.metadata == metadata

      assert {:error, changeset} =
               Artifacts.update(user.id, artifact.id, %{filename: "not-persisted.jsonl"}, %{
                 metadata: Map.delete(metadata, "format")
               })

      assert %{metadata: metadata_errors} = errors_on(changeset)
      assert is_map(metadata_errors)
      assert {:ok, persisted_artifact} = ArtifactsRepo.get_in_scope(user.id, artifact.id)
      assert persisted_artifact.filename == artifact.filename

      assert [link] = ArtifactLinks.list_by_artifact(user.id, project.id, artifact.id)
      assert link.metadata.version == metadata["version"]
      assert link.metadata.content_kind == metadata["content_kind"]
      assert link.metadata.format == metadata["format"]
      assert link.metadata.origin == metadata["origin"]
      assert link.metadata.presentation == metadata["presentation"]
      assert link.metadata.extensions == metadata["extensions"]
    end

    test "updates a sole attachment's logical name and preserves it when moving the attachment",
         %{
           user: user,
           project: project,
           task: task
         } do
      assert {:ok, %{artifact: artifact}} =
               Artifacts.create_and_link(
                 user.id,
                 project.id,
                 artifact_attrs(),
                 link_attrs("project", project.id, %{logical_name: "implementation_plan"})
               )

      assert {:ok, renamed_artifact} =
               Artifacts.update(user.id, artifact.id, %{}, %{logical_name: "result"})

      assert renamed_artifact.logical_name == "result"

      assert {:ok, moved_artifact} =
               Artifacts.update(
                 user.id,
                 artifact.id,
                 %{},
                 %{subject_type: "task", subject_id: task.id}
               )

      assert moved_artifact.logical_name == "result"
      assert [link] = ArtifactLinks.list_by_artifact(user.id, project.id, artifact.id)
      assert link.subject_type == "task"
      assert link.subject_id == task.id
      assert link.logical_name == "result"
    end

    test "updates file fields and replaces its sole attachment within the project", %{
      user: user,
      project: project,
      task: task
    } do
      assert {:ok, %{artifact: artifact}} =
               Artifacts.create_and_link(
                 user.id,
                 project.id,
                 artifact_attrs(),
                 link_attrs("project", project.id, %{
                   metadata: conversation_metadata(%{"content_kind" => "result"})
                 })
               )

      assert {:ok, updated_artifact} =
               Artifacts.update(
                 user.id,
                 artifact.id,
                 %{filename: "task-result.json", body: ~s({"status":"complete"})},
                 %{subject_type: "task", subject_id: task.id}
               )

      assert updated_artifact.filename == "task-result.json"
      assert updated_artifact.body == ~s({"status":"complete"})
      assert [] = Artifacts.list_for_subject(user.id, project.id, "project", project.id)
      assert [listed_artifact] = Artifacts.list_for_subject(user.id, project.id, "task", task.id)
      assert listed_artifact.id == artifact.id

      assert [link] = ArtifactLinks.list_by_artifact(user.id, project.id, artifact.id)
      assert link.subject_type == "task"
      assert link.subject_id == task.id
      assert link.metadata.content_kind == "result"
    end

    test "rolls back file and attachment changes outside the artifact scope", %{
      user: user,
      project: project
    } do
      assert {:ok, %{artifact: artifact, link: original_link}} =
               Artifacts.create_and_link(
                 user.id,
                 project.id,
                 artifact_attrs(),
                 link_attrs("project", project.id)
               )

      other_project = create_project(user, "Other Update Project")
      other_project_task = create_task(user, other_project, "Other project update target")

      other_user = create_user("other-update-owner")
      other_user_project = create_project(other_user, "Other User Update Project")

      other_user_task =
        create_task(other_user, other_user_project, "Other user update target")

      for subject_id <- [other_project_task.id, other_user_task.id] do
        assert {:error, :subject_scope_mismatch} =
                 Artifacts.update(
                   user.id,
                   artifact.id,
                   %{filename: "forbidden.md", body: "Forbidden"},
                   %{subject_type: "task", subject_id: subject_id}
                 )

        assert {:ok, persisted_artifact} = ArtifactsRepo.get_in_scope(user.id, artifact.id)
        assert persisted_artifact.filename == artifact.filename
        assert persisted_artifact.body == artifact.body

        assert [persisted_link] =
                 ArtifactLinks.list_by_artifact(user.id, project.id, artifact.id)

        assert persisted_link.id == original_link.id
      end
    end

    test "rejects ambiguous attachment replacement without rolling back field-only updates", %{
      user: user,
      project: project,
      task: task
    } do
      artifact = create_artifact(user, project, %{})
      link_artifact(user, project, artifact, "project", project.id)
      link_artifact(user, project, artifact, "task", task.id)

      assert {:error, :ambiguous_attachment} =
               Artifacts.update(
                 user.id,
                 artifact.id,
                 %{filename: "ambiguous.md"},
                 %{subject_type: "project", subject_id: project.id}
               )

      assert {:ok, persisted_artifact} = ArtifactsRepo.get_in_scope(user.id, artifact.id)
      assert persisted_artifact.filename == artifact.filename

      assert {:ok, updated_artifact} =
               Artifacts.update(user.id, artifact.id, %{filename: "field-only.md"})

      assert updated_artifact.filename == "field-only.md"
      assert length(ArtifactLinks.list_by_artifact(user.id, project.id, artifact.id)) == 2
    end

    test "does not update another user's artifact", %{user: user, project: project} do
      artifact = create_artifact(user, project, %{})
      other_user = create_user("other-artifact-updater")

      assert {:error, :not_found} =
               Artifacts.update(other_user.id, artifact.id, %{filename: "forbidden.md"})

      assert {:ok, persisted_artifact} = ArtifactsRepo.get_in_scope(user.id, artifact.id)
      assert persisted_artifact.filename == artifact.filename
    end
  end

  describe "delete/2" do
    setup [:setup_artifact_scope]

    test "deletes an owned artifact and cascades its links", %{
      user: user,
      project: project,
      task: task
    } do
      artifact = create_artifact(user, project, %{})
      link_artifact(user, project, artifact, "project", project.id)
      link_artifact(user, project, artifact, "task", task.id)

      assert {:ok, deleted_artifact} = Artifacts.delete(user.id, artifact.id)
      assert deleted_artifact.id == artifact.id
      assert {:error, :not_found} = ArtifactsRepo.get_in_scope(user.id, artifact.id)
      assert ArtifactLinks.list_by_artifact(user.id, project.id, artifact.id) == []
    end

    test "does not delete another user's artifact", %{user: user, project: project} do
      artifact = create_artifact(user, project, %{})
      other_user = create_user("other-artifact-deleter")

      assert {:error, :not_found} = Artifacts.delete(other_user.id, artifact.id)
      assert {:ok, persisted_artifact} = ArtifactsRepo.get_in_scope(user.id, artifact.id)
      assert persisted_artifact.id == artifact.id
    end
  end

  describe "list_for_subject/4" do
    setup [:setup_artifact_scope]

    test "returns all files attached to a task subject", %{
      user: user,
      project: project,
      task: task
    } do
      markdown_artifact = create_artifact(user, project, %{filename: "task-notes.md"})

      json_artifact =
        create_artifact(user, project, %{
          filename: "task-result.json",
          body: ~s({"result":{"state":"complete"}})
        })

      for artifact <- [markdown_artifact, json_artifact] do
        link_artifact(user, project, artifact, "task", task.id)
      end

      listed = Artifacts.list_for_subject(user.id, project.id, "task", task.id)
      listed_ids = Enum.map(listed, & &1.id)

      assert markdown_artifact.id in listed_ids
      assert json_artifact.id in listed_ids
      assert Enum.find(listed, &(&1.id == json_artifact.id)).body == json_artifact.body
    end

    test "returns only files linked to the requested task section", %{
      user: user,
      project: project,
      section: section
    } do
      section_artifact = create_artifact(user, project, %{filename: "section-evidence.md"})

      unlinked_artifact = create_artifact(user, project, %{filename: "unlinked-evidence.md"})

      link_artifact(user, project, section_artifact, "task_section", section.id)

      listed_ids =
        user.id
        |> Artifacts.list_for_subject(project.id, "task_section", section.id)
        |> Enum.map(& &1.id)

      assert listed_ids == [section_artifact.id]
      refute unlinked_artifact.id in listed_ids
    end

    test "does not leak artifacts to another caller", %{
      user: user,
      project: project,
      task: task
    } do
      other_user = create_user("other-artifact-caller")
      artifact = create_artifact(user, project, %{filename: "caller-scoped-plan.md"})
      link_artifact(user, project, artifact, "task", task.id)

      assert [] = Artifacts.list_for_subject(other_user.id, project.id, "task", task.id)
    end
  end

  describe "get_for_subject_by_logical_name/5" do
    setup [:setup_artifact_scope]

    test "provides a scoped lookup contract for CLI and orchestrator callers", %{
      user: user,
      project: project,
      task: task
    } do
      assert {:ok, %{artifact: artifact}} =
               Artifacts.create_and_link(
                 user.id,
                 project.id,
                 artifact_attrs(%{filename: "orchestrator-result.json"}),
                 link_attrs("task", task.id, %{logical_name: "result"})
               )

      assert {:ok, found} =
               Artifacts.get_for_subject_by_logical_name(
                 user.id,
                 project.id,
                 "task",
                 task.id,
                 "result"
               )

      assert found.id == artifact.id
      assert found.filename == "orchestrator-result.json"
      assert found.logical_name == "result"

      other_project = create_project(user, "Other named artifact project")
      other_task = create_task(user, other_project, "Other named artifact task")

      assert {:error, :not_found} =
               Artifacts.get_for_subject_by_logical_name(
                 user.id,
                 other_project.id,
                 "task",
                 other_task.id,
                 "result"
               )

      other_user = create_user("other_named_owner")

      assert {:error, :not_found} =
               Artifacts.get_for_subject_by_logical_name(
                 other_user.id,
                 project.id,
                 "task",
                 task.id,
                 "result"
               )
    end
  end

  describe "API boundary" do
    test "keeps the service independent from CLI and GraphQL modules" do
      source = File.read!("lib/sacrum/accounts/artifacts.ex")

      refute source =~ "SacrumWeb"
      refute source =~ "GraphQL"
      refute source =~ "Absinthe"
      refute source =~ "Vtb"
      refute source =~ "CLI"
    end
  end
end
