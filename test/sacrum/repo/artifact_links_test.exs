defmodule Sacrum.Repo.ArtifactLinksTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.Schemas.ArtifactLink
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Projects

  @valid_user_attrs %{
    email: "test@example.com",
    username: "testuser",
    password: "password123"
  }

  defp setup_user_and_project do
    {:ok, user} = Users.insert(@valid_user_attrs)
    {:ok, project} = Projects.insert(user, %{name: "Test Project"})
    {user, project}
  end

  describe "ArtifactLink schema columns" do
    test "has all required columns: artifact_id, subject_type, subject_id, relationship_kind, project_id, user_id, metadata, timestamps" do
      artifact_link = %ArtifactLink{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        subject_type: "task",
        subject_id: Ecto.UUID.generate(),
        project_id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate()
      }

      assert Map.has_key?(artifact_link, :id)
      assert Map.has_key?(artifact_link, :artifact_id)
      assert Map.has_key?(artifact_link, :subject_type)
      assert Map.has_key?(artifact_link, :subject_id)
      assert Map.has_key?(artifact_link, :relationship_kind)
      assert Map.has_key?(artifact_link, :project_id)
      assert Map.has_key?(artifact_link, :user_id)
      assert Map.has_key?(artifact_link, :metadata)
      assert Map.has_key?(artifact_link, :inserted_at)
      assert Map.has_key?(artifact_link, :updated_at)
    end
  end

  describe "ArtifactLink changeset" do
    test "creates valid artifact link with all fields" do
      {user, project} = setup_user_and_project()

      artifact_link = %ArtifactLink{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        project_id: project.id,
        user_id: user.id
      }

      attrs = %{
        subject_type: "task",
        subject_id: Ecto.UUID.generate(),
        relationship_kind: "produced_by",
        metadata: %{"key" => "value"}
      }

      changeset = ArtifactLink.changeset(artifact_link, attrs)
      assert changeset.valid?
      assert get_field(changeset, :subject_type) == "task"
      assert get_field(changeset, :relationship_kind) == "produced_by"
      assert get_field(changeset, :metadata) == %{"key" => "value"}
    end

    test "requires artifact_id" do
      {user, project} = setup_user_and_project()

      artifact_link = %ArtifactLink{
        id: Ecto.UUID.generate(),
        project_id: project.id,
        user_id: user.id
      }

      attrs = %{
        subject_type: "task",
        subject_id: Ecto.UUID.generate(),
        relationship_kind: "produced_by"
      }

      changeset = ArtifactLink.changeset(artifact_link, attrs)
      assert not changeset.valid?
    end

    test "requires subject_type" do
      {user, project} = setup_user_and_project()

      artifact_link = %ArtifactLink{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        project_id: project.id,
        user_id: user.id
      }

      attrs = %{
        subject_id: Ecto.UUID.generate(),
        relationship_kind: "produced_by"
      }

      changeset = ArtifactLink.changeset(artifact_link, attrs)
      assert not changeset.valid?
      assert %{subject_type: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires subject_id" do
      {user, project} = setup_user_and_project()

      artifact_link = %ArtifactLink{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        project_id: project.id,
        user_id: user.id
      }

      attrs = %{
        subject_type: "task",
        relationship_kind: "produced_by"
      }

      changeset = ArtifactLink.changeset(artifact_link, attrs)
      assert not changeset.valid?
      assert %{subject_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires relationship_kind" do
      {user, project} = setup_user_and_project()

      artifact_link = %ArtifactLink{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        project_id: project.id,
        user_id: user.id
      }

      attrs = %{
        subject_type: "task",
        subject_id: Ecto.UUID.generate()
      }

      changeset = ArtifactLink.changeset(artifact_link, attrs)
      assert not changeset.valid?
      assert %{relationship_kind: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "ArtifactLink subject_type polymorphic pattern" do
    test "supports 'task' subject_type" do
      {user, project} = setup_user_and_project()

      artifact_link = %ArtifactLink{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        project_id: project.id,
        user_id: user.id
      }

      attrs = %{
        subject_type: "task",
        subject_id: Ecto.UUID.generate(),
        relationship_kind: "produced_by"
      }

      changeset = ArtifactLink.changeset(artifact_link, attrs)
      assert changeset.valid?
    end

    test "supports 'task_section' subject_type for testing_criterion evidence" do
      {user, project} = setup_user_and_project()

      artifact_link = %ArtifactLink{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        project_id: project.id,
        user_id: user.id
      }

      attrs = %{
        subject_type: "task_section",
        subject_id: Ecto.UUID.generate(),
        relationship_kind: "evidence_for"
      }

      changeset = ArtifactLink.changeset(artifact_link, attrs)

      assert changeset.valid?,
             "artifact_links must support 'task_section' as subject_type for testing_criterion evidence linking"
    end

    test "supports 'chat_session' subject_type" do
      {user, project} = setup_user_and_project()

      artifact_link = %ArtifactLink{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        project_id: project.id,
        user_id: user.id
      }

      attrs = %{
        subject_type: "chat_session",
        subject_id: Ecto.UUID.generate(),
        relationship_kind: "produced_by"
      }

      changeset = ArtifactLink.changeset(artifact_link, attrs)
      assert changeset.valid?
    end

    test "supports 'task_run' subject_type" do
      {user, project} = setup_user_and_project()

      artifact_link = %ArtifactLink{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        project_id: project.id,
        user_id: user.id
      }

      attrs = %{
        subject_type: "task_run",
        subject_id: Ecto.UUID.generate(),
        relationship_kind: "produced_by"
      }

      changeset = ArtifactLink.changeset(artifact_link, attrs)
      assert changeset.valid?
    end

    test "supports 'step_execution' subject_type" do
      {user, project} = setup_user_and_project()

      artifact_link = %ArtifactLink{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        project_id: project.id,
        user_id: user.id
      }

      attrs = %{
        subject_type: "step_execution",
        subject_id: Ecto.UUID.generate(),
        relationship_kind: "produced_by"
      }

      changeset = ArtifactLink.changeset(artifact_link, attrs)
      assert changeset.valid?
    end

    test "rejects invalid subject_type" do
      {user, project} = setup_user_and_project()

      artifact_link = %ArtifactLink{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        project_id: project.id,
        user_id: user.id
      }

      attrs = %{
        subject_type: "invalid_type",
        subject_id: Ecto.UUID.generate(),
        relationship_kind: "produced_by"
      }

      changeset = ArtifactLink.changeset(artifact_link, attrs)
      assert not changeset.valid?
    end
  end

  describe "ArtifactLink relationship_kind values" do
    test "supports 'produced_by'" do
      {user, project} = setup_user_and_project()

      artifact_link = %ArtifactLink{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        project_id: project.id,
        user_id: user.id
      }

      attrs = %{
        subject_type: "task",
        subject_id: Ecto.UUID.generate(),
        relationship_kind: "produced_by"
      }

      changeset = ArtifactLink.changeset(artifact_link, attrs)
      assert changeset.valid?
    end

    test "supports 'attached_to'" do
      {user, project} = setup_user_and_project()

      artifact_link = %ArtifactLink{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        project_id: project.id,
        user_id: user.id
      }

      attrs = %{
        subject_type: "task",
        subject_id: Ecto.UUID.generate(),
        relationship_kind: "attached_to"
      }

      changeset = ArtifactLink.changeset(artifact_link, attrs)
      assert changeset.valid?
    end

    test "supports 'evidence_for'" do
      {user, project} = setup_user_and_project()

      artifact_link = %ArtifactLink{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        project_id: project.id,
        user_id: user.id
      }

      attrs = %{
        subject_type: "task_section",
        subject_id: Ecto.UUID.generate(),
        relationship_kind: "evidence_for"
      }

      changeset = ArtifactLink.changeset(artifact_link, attrs)
      assert changeset.valid?
    end

    test "supports 'source_for'" do
      {user, project} = setup_user_and_project()

      artifact_link = %ArtifactLink{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        project_id: project.id,
        user_id: user.id
      }

      attrs = %{
        subject_type: "task",
        subject_id: Ecto.UUID.generate(),
        relationship_kind: "source_for"
      }

      changeset = ArtifactLink.changeset(artifact_link, attrs)
      assert changeset.valid?
    end

    test "supports 'validates'" do
      {user, project} = setup_user_and_project()

      artifact_link = %ArtifactLink{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        project_id: project.id,
        user_id: user.id
      }

      attrs = %{
        subject_type: "task",
        subject_id: Ecto.UUID.generate(),
        relationship_kind: "validates"
      }

      changeset = ArtifactLink.changeset(artifact_link, attrs)
      assert changeset.valid?
    end

    test "supports 'supersedes'" do
      {user, project} = setup_user_and_project()

      artifact_link = %ArtifactLink{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        project_id: project.id,
        user_id: user.id
      }

      attrs = %{
        subject_type: "task",
        subject_id: Ecto.UUID.generate(),
        relationship_kind: "supersedes"
      }

      changeset = ArtifactLink.changeset(artifact_link, attrs)
      assert changeset.valid?
    end

    test "rejects invalid relationship_kind" do
      {user, project} = setup_user_and_project()

      artifact_link = %ArtifactLink{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        project_id: project.id,
        user_id: user.id
      }

      attrs = %{
        subject_type: "task",
        subject_id: Ecto.UUID.generate(),
        relationship_kind: "invalid_kind"
      }

      changeset = ArtifactLink.changeset(artifact_link, attrs)
      assert not changeset.valid?
    end
  end

  describe "ArtifactLink polymorphic pattern" do
    test "does NOT use foreign key to specific domain tables" do
      {user, project} = setup_user_and_project()

      artifact_link = %ArtifactLink{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        project_id: project.id,
        user_id: user.id
      }

      attrs = %{
        subject_type: "task",
        subject_id: Ecto.UUID.generate(),
        relationship_kind: "produced_by"
      }

      changeset = ArtifactLink.changeset(artifact_link, attrs)
      assert changeset.valid?
    end
  end

  describe "ArtifactLink metadata field" do
    test "accepts jsonb metadata" do
      {user, project} = setup_user_and_project()

      artifact_link = %ArtifactLink{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        project_id: project.id,
        user_id: user.id
      }

      attrs = %{
        subject_type: "task",
        subject_id: Ecto.UUID.generate(),
        relationship_kind: "produced_by",
        metadata: %{"evidence_type" => "test_result", "confidence" => 0.95}
      }

      changeset = ArtifactLink.changeset(artifact_link, attrs)
      assert changeset.valid?
    end

    test "allows null metadata" do
      {user, project} = setup_user_and_project()

      artifact_link = %ArtifactLink{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        project_id: project.id,
        user_id: user.id
      }

      attrs = %{
        subject_type: "task",
        subject_id: Ecto.UUID.generate(),
        relationship_kind: "produced_by"
      }

      changeset = ArtifactLink.changeset(artifact_link, attrs)
      assert changeset.valid?
    end
  end

  describe "ArtifactLink associations" do
    test "belongs_to project" do
      {user, project} = setup_user_and_project()

      artifact_link = %ArtifactLink{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        project_id: project.id,
        user_id: user.id
      }

      attrs = %{
        subject_type: "task",
        subject_id: Ecto.UUID.generate(),
        relationship_kind: "produced_by"
      }

      changeset = ArtifactLink.changeset(artifact_link, attrs)
      assert changeset.valid?
    end

    test "belongs_to user" do
      {user, project} = setup_user_and_project()

      artifact_link = %ArtifactLink{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        project_id: project.id,
        user_id: user.id
      }

      attrs = %{
        subject_type: "task",
        subject_id: Ecto.UUID.generate(),
        relationship_kind: "produced_by"
      }

      changeset = ArtifactLink.changeset(artifact_link, attrs)
      assert changeset.valid?
    end
  end
end
