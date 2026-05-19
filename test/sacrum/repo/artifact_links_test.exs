defmodule Sacrum.Repo.ArtifactLinksTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.ArtifactLinks
  alias Sacrum.Repo.Artifacts
  alias Sacrum.Repo.ChatSessions
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.TaskSections
  alias Sacrum.Repo.Tasks
  alias Sacrum.Repo.Users

  defp create_user(prefix \\ "artifact-link") do
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

  defp create_project(user, name \\ "Artifact Link Project") do
    {:ok, project} = Projects.insert(user, %{name: name})
    project
  end

  defp create_artifact(user, project, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          artifact_type: "task_draft",
          artifact_state: "draft",
          visibility: "public",
          redaction_state: "not_needed",
          title: "Draft task",
          content: "Task body"
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

  defp create_chat_session(user, project) do
    {:ok, chat_session} = ChatSessions.insert(user.id, project.id, %{session_kind: "planning"})
    chat_session
  end

  defp setup_link_scope(_context) do
    user = create_user()
    project = create_project(user)
    task = create_task(project)
    section = create_section(task)
    chat_session = create_chat_session(user, project)
    artifact = create_artifact(user, project)

    %{
      user: user,
      project: project,
      task: task,
      section: section,
      chat_session: chat_session,
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
      chat_session: chat_session
    } do
      subjects = [
        {"task", task.id, "attached_to"},
        {"task_section", section.id, "evidence_for"},
        {"chat_session", chat_session.id, "attached_to"}
      ]

      for {subject_type, subject_id, relationship_kind} <- subjects do
        assert {:ok, link} =
                 ArtifactLinks.insert(user.id, project.id, artifact.id, %{
                   subject_type: subject_type,
                   subject_id: subject_id,
                   relationship_kind: relationship_kind
                 })

        assert link.artifact_id == artifact.id
        assert link.subject_type == subject_type
        assert link.subject_id == subject_id
        assert link.relationship_kind == relationship_kind
        assert link.project_id == project.id
        assert link.user_id == user.id
      end
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
                 subject_id: other_project_task.id,
                 relationship_kind: "attached_to"
               })
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
                 subject_id: task.id,
                 relationship_kind: "attached_to"
               })
    end
  end

  describe "scoped reads" do
    setup [:setup_link_scope]

    test "lists links by subject without leaking links outside project or user scope", %{
      user: user,
      project: project,
      task: task,
      artifact: artifact
    } do
      other_project = create_project(user, "Other Link Project")
      other_project_task = create_task(other_project, "Other linked task")
      other_project_artifact = create_artifact(user, other_project, %{title: "Other plan"})

      other_user = create_user("other-subject-link")
      other_user_project = create_project(other_user, "Other User Project")
      other_user_task = create_task(other_user_project, "Other user task")
      other_user_artifact = create_artifact(other_user, other_user_project)

      {:ok, link} =
        ArtifactLinks.insert(user.id, project.id, artifact.id, %{
          subject_type: "task",
          subject_id: task.id,
          relationship_kind: "attached_to"
        })

      {:ok, other_project_link} =
        ArtifactLinks.insert(user.id, other_project.id, other_project_artifact.id, %{
          subject_type: "task",
          subject_id: other_project_task.id,
          relationship_kind: "attached_to"
        })

      {:ok, other_user_link} =
        ArtifactLinks.insert(other_user.id, other_user_project.id, other_user_artifact.id, %{
          subject_type: "task",
          subject_id: other_user_task.id,
          relationship_kind: "attached_to"
        })

      listed_ids =
        user.id
        |> ArtifactLinks.list_by_subject(project.id, "task", task.id)
        |> Enum.map(& &1.id)

      assert link.id in listed_ids
      refute other_project_link.id in listed_ids
      refute other_user_link.id in listed_ids
    end

    test "lists links by artifact without leaking links outside project or user scope", %{
      user: user,
      project: project,
      artifact: artifact,
      task: task,
      section: section
    } do
      other_project = create_project(user, "Other Artifact Link Project")
      other_project_artifact = create_artifact(user, other_project, %{title: "Other artifact"})
      other_project_task = create_task(other_project, "Other artifact task")

      {:ok, task_link} =
        ArtifactLinks.insert(user.id, project.id, artifact.id, %{
          subject_type: "task",
          subject_id: task.id,
          relationship_kind: "attached_to"
        })

      {:ok, section_link} =
        ArtifactLinks.insert(user.id, project.id, artifact.id, %{
          subject_type: "task_section",
          subject_id: section.id,
          relationship_kind: "evidence_for"
        })

      {:ok, other_project_link} =
        ArtifactLinks.insert(user.id, other_project.id, other_project_artifact.id, %{
          subject_type: "task",
          subject_id: other_project_task.id,
          relationship_kind: "attached_to"
        })

      listed_ids =
        user.id
        |> ArtifactLinks.list_by_artifact(project.id, artifact.id)
        |> Enum.map(& &1.id)

      assert task_link.id in listed_ids
      assert section_link.id in listed_ids
      refute other_project_link.id in listed_ids
    end
  end
end
