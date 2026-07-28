defmodule Sacrum.Accounts.ArtifactsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.Artifacts
  alias Sacrum.Accounts.Projects
  alias Sacrum.Accounts.Tasks
  alias Sacrum.Repo
  alias Sacrum.Repo.ArtifactLinks
  alias Sacrum.Repo.Artifacts, as: ArtifactsRepo
  alias Sacrum.Repo.Schemas.{Artifact, ArtifactLink}
  alias Sacrum.Repo.TaskSections
  alias Sacrum.Repo.Users

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
        subject_id: subject_id,
        relationship_kind: "attached_to"
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
        subject_id: subject_id,
        relationship_kind: "attached_to"
      },
      attrs
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
                 link_attrs("task", task.id, %{relationship_kind: "evidence_for"})
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
      assert link.relationship_kind == "evidence_for"

      assert Repo.aggregate(Artifact, :count) == 1
      assert Repo.aggregate(ArtifactLink, :count) == 1
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

    test "does not leak visible artifacts to another caller", %{
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
