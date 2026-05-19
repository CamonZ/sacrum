defmodule Sacrum.Accounts.ArtifactsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.Artifacts
  alias Sacrum.Accounts.Projects
  alias Sacrum.Accounts.Tasks
  alias Sacrum.Repo
  alias Sacrum.Repo.ArtifactLinks
  alias Sacrum.Repo.Artifacts, as: ArtifactsRepo
  alias Sacrum.Repo.ChatSessions
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

  defp create_chat_session(user, project) do
    {:ok, session} = ChatSessions.insert(user.id, project.id, %{session_kind: "planning"})
    session
  end

  defp create_artifact(user, project, attrs) do
    attrs =
      Map.merge(
        %{
          artifact_type: "plan",
          artifact_state: "draft",
          visibility: "public",
          redaction_state: "not_needed",
          title: "Implementation plan",
          content: "Persist through the artifact domain service.",
          data: %{"source" => "unit-test"}
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
        artifact_type: "plan",
        artifact_state: "draft",
        visibility: "public",
        redaction_state: "not_needed",
        title: "Scoped artifact",
        content: "Created and linked below the API layer."
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
    chat_session = create_chat_session(user, project)

    %{
      user: user,
      project: project,
      task: task,
      section: section,
      chat_session: chat_session
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
                 artifact_attrs(%{title: "Task plan"}),
                 link_attrs("task", task.id, %{relationship_kind: "evidence_for"})
               )

      assert artifact.user_id == user.id
      assert artifact.project_id == project.id
      assert artifact.title == "Task plan"

      assert link.user_id == user.id
      assert link.project_id == project.id
      assert link.artifact_id == artifact.id
      assert link.subject_type == "task"
      assert link.subject_id == task.id
      assert link.relationship_kind == "evidence_for"

      assert Repo.aggregate(Artifact, :count) == 1
      assert Repo.aggregate(ArtifactLink, :count) == 1
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

    test "returns only public and redacted-safe artifacts for a task subject", %{
      user: user,
      project: project,
      task: task
    } do
      public_artifact = create_artifact(user, project, %{title: "Visible plan"})

      redacted_artifact =
        create_artifact(user, project, %{title: "Redacted summary", redaction_state: "redacted"})

      internal_artifact =
        create_artifact(user, project, %{title: "Internal trace", visibility: "internal"})

      blocked_artifact =
        create_artifact(user, project, %{title: "Blocked draft", redaction_state: "blocked"})

      for artifact <- [public_artifact, redacted_artifact, internal_artifact, blocked_artifact] do
        link_artifact(user, project, artifact, "task", task.id)
      end

      listed_ids =
        user.id
        |> Artifacts.list_for_subject(project.id, "task", task.id)
        |> Enum.map(& &1.id)

      assert public_artifact.id in listed_ids
      assert redacted_artifact.id in listed_ids
      refute internal_artifact.id in listed_ids
      refute blocked_artifact.id in listed_ids
    end

    test "returns only public and redacted-safe artifacts for a task_section subject", %{
      user: user,
      project: project,
      section: section
    } do
      public_artifact = create_artifact(user, project, %{title: "Visible section evidence"})

      internal_artifact =
        create_artifact(user, project, %{
          title: "Internal section evidence",
          visibility: "internal"
        })

      link_artifact(user, project, public_artifact, "task_section", section.id)
      link_artifact(user, project, internal_artifact, "task_section", section.id)

      listed_ids =
        user.id
        |> Artifacts.list_for_subject(project.id, "task_section", section.id)
        |> Enum.map(& &1.id)

      assert listed_ids == [public_artifact.id]
    end

    test "returns scoped public artifacts for a chat_session subject", %{
      user: user,
      project: project,
      chat_session: chat_session
    } do
      artifact = create_artifact(user, project, %{title: "Chat planning output"})
      link_artifact(user, project, artifact, "chat_session", chat_session.id)

      assert [%Artifact{id: artifact_id}] =
               Artifacts.list_for_subject(user.id, project.id, "chat_session", chat_session.id)

      assert artifact_id == artifact.id
    end

    test "does not leak visible artifacts to another caller", %{
      user: user,
      project: project,
      task: task
    } do
      other_user = create_user("other-artifact-caller")
      artifact = create_artifact(user, project, %{title: "Caller-scoped plan"})
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
