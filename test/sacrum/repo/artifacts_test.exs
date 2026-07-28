defmodule Sacrum.Repo.ArtifactsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.ArtifactLinks
  alias Sacrum.Repo.Artifacts
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Schemas.Artifact
  alias Sacrum.Repo.Tasks
  alias Sacrum.Repo.Users

  defp create_user(prefix \\ "artifact") do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Users.insert(%{
        email: "#{prefix}-#{suffix}@example.com",
        username: "#{prefix}_#{suffix}",
        password: "password123"
      })

    user
  end

  defp create_project(user, name \\ "Artifact Project") do
    {:ok, project} = Projects.insert(user, %{name: name})
    project
  end

  defp setup_artifact_project(_context) do
    user = create_user()
    project = create_project(user)

    %{user: user, project: project}
  end

  defp valid_attrs(attrs \\ %{}) do
    Map.merge(
      %{
        filename: "implementation-plan.md",
        body: "# Implementation plan\n\nCreate the persistence boundary through the repo layer."
      },
      attrs
    )
  end

  defp create_task(project, title \\ "Artifact subject") do
    {:ok, task} = Tasks.insert(project, %{title: title})
    task
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

  describe "insert/3" do
    setup [:setup_artifact_project]

    test "creates an artifact scoped to the user and project", %{user: user, project: project} do
      assert {:ok, artifact} =
               Artifacts.insert(user.id, project.id, valid_attrs())

      assert Artifact == artifact.__struct__
      assert artifact.user_id == user.id
      assert artifact.project_id == project.id
      assert artifact.filename == "implementation-plan.md"

      assert artifact.body ==
               "# Implementation plan\n\nCreate the persistence boundary through the repo layer."
    end

    test "rejects creating an artifact in another user's project", %{project: project} do
      other_user = create_user("other_artifact")

      assert {:error, :not_found} =
               Artifacts.insert(other_user.id, project.id, valid_attrs())
    end
  end

  describe "update/2" do
    setup [:setup_artifact_project]

    test "persists filename and body changes", %{user: user, project: project} do
      {:ok, artifact} = Artifacts.insert(user.id, project.id, valid_attrs())
      json_body = ~s({"steps":["migration","schema","repo"],"complete":true})

      assert {:ok, updated_artifact} =
               Artifacts.update(artifact, %{
                 filename: "implementation-result.json",
                 body: json_body
               })

      assert updated_artifact.id == artifact.id
      assert updated_artifact.user_id == user.id
      assert updated_artifact.project_id == project.id
      assert updated_artifact.filename == "implementation-result.json"
      assert updated_artifact.body == json_body

      assert {:ok, persisted_artifact} = Artifacts.get(artifact.id)
      assert persisted_artifact.filename == "implementation-result.json"
      assert persisted_artifact.body == json_body
    end
  end

  describe "list_for_project/3" do
    setup [:setup_artifact_project]

    test "lists Markdown and JSON files only within the user and project scope", %{
      user: user,
      project: project
    } do
      {:ok, markdown_artifact} =
        Artifacts.insert(user.id, project.id, valid_attrs())

      json_body = ~s({"steps":["migration","schema","repo"]})

      {:ok, json_artifact} =
        Artifacts.insert(
          user.id,
          project.id,
          valid_attrs(%{filename: "implementation-plan.json", body: json_body})
        )

      other_project = create_project(user, "Other Artifact Project")

      {:ok, other_project_artifact} =
        Artifacts.insert(
          user.id,
          other_project.id,
          valid_attrs(%{filename: "other-project.md"})
        )

      artifacts = Artifacts.list_for_project(user.id, project.id)
      listed_ids = Enum.map(artifacts, & &1.id)

      assert markdown_artifact.id in listed_ids
      assert json_artifact.id in listed_ids
      refute other_project_artifact.id in listed_ids
      assert Enum.find(artifacts, &(&1.id == json_artifact.id)).body == json_body

      other_user = create_user("other_artifact_reader")
      assert [] = Artifacts.list_for_project(other_user.id, project.id)
    end
  end

  describe "list_for_subject/5" do
    setup [:setup_artifact_project]

    test "returns only files linked to the scoped subject", %{user: user, project: project} do
      task = create_task(project)
      other_task = create_task(project, "Other artifact subject")

      {:ok, linked_markdown} =
        Artifacts.insert(user.id, project.id, valid_attrs(%{filename: "task.md"}))

      json_body = ~s({"status":"ready"})

      {:ok, linked_json} =
        Artifacts.insert(
          user.id,
          project.id,
          valid_attrs(%{filename: "task.json", body: json_body})
        )

      {:ok, unlinked} =
        Artifacts.insert(user.id, project.id, valid_attrs(%{filename: "unlinked.md"}))

      {:ok, other_subject_artifact} =
        Artifacts.insert(user.id, project.id, valid_attrs(%{filename: "other-task.md"}))

      link_artifact(user, project, linked_markdown, "task", task.id)
      link_artifact(user, project, linked_json, "task", task.id)
      link_artifact(user, project, other_subject_artifact, "task", other_task.id)

      artifacts = Artifacts.list_for_subject(user.id, project.id, "task", task.id)
      listed_ids = Enum.map(artifacts, & &1.id)

      assert linked_markdown.id in listed_ids
      assert linked_json.id in listed_ids
      refute unlinked.id in listed_ids
      refute other_subject_artifact.id in listed_ids
      assert Enum.find(artifacts, &(&1.id == linked_json.id)).body == json_body

      other_user = create_user("other_subject_reader")
      assert [] = Artifacts.list_for_subject(other_user.id, project.id, "task", task.id)
    end
  end
end
