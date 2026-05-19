defmodule Sacrum.Repo.ArtifactsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.Artifacts
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Schemas.Artifact
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
        artifact_type: "plan",
        artifact_state: "draft",
        visibility: "public",
        redaction_state: "not_needed",
        title: "Implementation plan",
        content: "Create the persistence boundary through the repo layer.",
        data: %{"steps" => ["migration", "schema", "repo"]}
      },
      attrs
    )
  end

  describe "insert/3" do
    setup [:setup_artifact_project]

    test "creates an artifact scoped to the user and project", %{user: user, project: project} do
      assert {:ok, artifact} =
               Artifacts.insert(user.id, project.id, valid_attrs(%{storage_ref: "blob://plan-1"}))

      assert Artifact == artifact.__struct__
      assert artifact.user_id == user.id
      assert artifact.project_id == project.id
      assert artifact.artifact_type == "plan"
      assert artifact.artifact_state == "draft"
      assert artifact.visibility == "public"
      assert artifact.redaction_state == "not_needed"
      assert artifact.storage_ref == "blob://plan-1"
      assert artifact.data == %{"steps" => ["migration", "schema", "repo"]}
    end

    test "rejects creating an artifact in another user's project", %{project: project} do
      other_user = create_user("other_artifact")

      assert {:error, :not_found} =
               Artifacts.insert(other_user.id, project.id, valid_attrs())
    end
  end

  describe "list_public_for_project/3" do
    setup [:setup_artifact_project]

    test "lists only public artifacts that are not blocked", %{user: user, project: project} do
      {:ok, public_artifact} =
        Artifacts.insert(user.id, project.id, valid_attrs(%{title: "Visible plan"}))

      {:ok, redacted_artifact} =
        Artifacts.insert(
          user.id,
          project.id,
          valid_attrs(%{title: "Redacted summary", redaction_state: "redacted"})
        )

      {:ok, internal_artifact} =
        Artifacts.insert(
          user.id,
          project.id,
          valid_attrs(%{title: "Operator trace", visibility: "internal"})
        )

      {:ok, blocked_artifact} =
        Artifacts.insert(
          user.id,
          project.id,
          valid_attrs(%{title: "Blocked draft", redaction_state: "blocked"})
        )

      other_project = create_project(user, "Other Artifact Project")

      {:ok, other_project_artifact} =
        Artifacts.insert(user.id, other_project.id, valid_attrs(%{title: "Other project"}))

      listed_ids =
        user.id
        |> Artifacts.list_public_for_project(project.id)
        |> Enum.map(& &1.id)

      assert public_artifact.id in listed_ids
      assert redacted_artifact.id in listed_ids
      refute internal_artifact.id in listed_ids
      refute blocked_artifact.id in listed_ids
      refute other_project_artifact.id in listed_ids
    end
  end
end
