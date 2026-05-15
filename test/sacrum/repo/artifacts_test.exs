defmodule Sacrum.Repo.ArtifactsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.Schemas.Artifact
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Projects

  @valid_user_attrs %{
    email: "test@example.com",
    username: "testuser",
    password: "password123"
  }

  @valid_artifact_attrs %{
    artifact_type: "task_draft",
    artifact_state: "draft",
    title: "Test Artifact",
    content: "Test content",
    visibility: "public",
    redaction_state: "not_needed"
  }

  defp setup_user_and_project do
    {:ok, user} = Users.insert(@valid_user_attrs)
    {:ok, project} = Projects.insert(user, %{name: "Test Project"})
    {user, project}
  end

  describe "Artifact schema columns" do
    test "has all required columns: project_id, user_id, artifact_type, artifact_state, title, content, data, storage_ref, visibility, redaction_state, timestamps" do
      {user, project} = setup_user_and_project()

      artifact = %Artifact{
        id: Ecto.UUID.generate(),
        project_id: project.id,
        user_id: user.id
      }

      # This test verifies the schema has the required fields defined
      assert Map.has_key?(artifact, :id)
      assert Map.has_key?(artifact, :project_id)
      assert Map.has_key?(artifact, :user_id)
      assert Map.has_key?(artifact, :artifact_type)
      assert Map.has_key?(artifact, :artifact_state)
      assert Map.has_key?(artifact, :title)
      assert Map.has_key?(artifact, :content)
      assert Map.has_key?(artifact, :data)
      assert Map.has_key?(artifact, :storage_ref)
      assert Map.has_key?(artifact, :visibility)
      assert Map.has_key?(artifact, :redaction_state)
      assert Map.has_key?(artifact, :inserted_at)
      assert Map.has_key?(artifact, :updated_at)
    end
  end

  describe "Artifact changeset" do
    test "creates valid artifact with all fields" do
      {user, project} = setup_user_and_project()

      artifact = %Artifact{
        id: Ecto.UUID.generate(),
        project_id: project.id,
        user_id: user.id
      }

      attrs =
        Map.merge(@valid_artifact_attrs, %{
          data: %{"key" => "value"},
          storage_ref: "s3://bucket/key"
        })

      changeset = Artifact.changeset(artifact, attrs)
      assert changeset.valid?
      assert get_field(changeset, :artifact_type) == "task_draft"
      assert get_field(changeset, :artifact_state) == "draft"
      assert get_field(changeset, :title) == "Test Artifact"
      assert get_field(changeset, :content) == "Test content"
      assert get_field(changeset, :visibility) == "public"
      assert get_field(changeset, :redaction_state) == "not_needed"
      assert get_field(changeset, :data) == %{"key" => "value"}
      assert get_field(changeset, :storage_ref) == "s3://bucket/key"
    end

    test "requires artifact_type" do
      {user, project} = setup_user_and_project()

      artifact = %Artifact{
        id: Ecto.UUID.generate(),
        project_id: project.id,
        user_id: user.id
      }

      attrs = Map.drop(@valid_artifact_attrs, [:artifact_type])
      changeset = Artifact.changeset(artifact, attrs)
      assert not changeset.valid?
      assert %{artifact_type: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires artifact_state" do
      {user, project} = setup_user_and_project()

      artifact = %Artifact{
        id: Ecto.UUID.generate(),
        project_id: project.id,
        user_id: user.id
      }

      attrs = Map.drop(@valid_artifact_attrs, [:artifact_state])
      changeset = Artifact.changeset(artifact, attrs)
      assert not changeset.valid?
      assert %{artifact_state: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires title" do
      {user, project} = setup_user_and_project()

      artifact = %Artifact{
        id: Ecto.UUID.generate(),
        project_id: project.id,
        user_id: user.id
      }

      attrs = Map.drop(@valid_artifact_attrs, [:title])
      changeset = Artifact.changeset(artifact, attrs)
      assert not changeset.valid?
      assert %{title: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires visibility" do
      {user, project} = setup_user_and_project()

      artifact = %Artifact{
        id: Ecto.UUID.generate(),
        project_id: project.id,
        user_id: user.id
      }

      attrs = Map.drop(@valid_artifact_attrs, [:visibility])
      changeset = Artifact.changeset(artifact, attrs)
      assert not changeset.valid?
      assert %{visibility: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates visibility is 'public' or 'internal'" do
      {user, project} = setup_user_and_project()

      artifact = %Artifact{
        id: Ecto.UUID.generate(),
        project_id: project.id,
        user_id: user.id
      }

      attrs = Map.merge(@valid_artifact_attrs, %{visibility: "invalid"})
      changeset = Artifact.changeset(artifact, attrs)
      assert not changeset.valid?
      assert %{visibility: ["is invalid"]} = errors_on(changeset)
    end

    test "validates artifact_state values" do
      {user, project} = setup_user_and_project()

      valid_states = ["draft", "pending_approval", "approved", "applied", "rejected"]

      for state <- valid_states do
        artifact = %Artifact{
          id: Ecto.UUID.generate(),
          project_id: project.id,
          user_id: user.id
        }

        attrs = Map.merge(@valid_artifact_attrs, %{artifact_state: state})
        changeset = Artifact.changeset(artifact, attrs)
        assert changeset.valid?, "artifact_state #{state} should be valid"
      end
    end

    test "validates redaction_state values" do
      {user, project} = setup_user_and_project()

      valid_states = ["not_needed", "redacted", "blocked"]

      for state <- valid_states do
        artifact = %Artifact{
          id: Ecto.UUID.generate(),
          project_id: project.id,
          user_id: user.id
        }

        attrs = Map.merge(@valid_artifact_attrs, %{redaction_state: state})
        changeset = Artifact.changeset(artifact, attrs)
        assert changeset.valid?, "redaction_state #{state} should be valid"
      end
    end
  end

  describe "Artifact associations" do
    test "belongs_to project" do
      {user, project} = setup_user_and_project()

      artifact = %Artifact{
        id: Ecto.UUID.generate(),
        project_id: project.id,
        user_id: user.id
      }

      changeset = Artifact.changeset(artifact, @valid_artifact_attrs)
      assert changeset.valid?
      assert get_field(changeset, :project_id) == project.id
    end

    test "belongs_to user" do
      {user, project} = setup_user_and_project()

      artifact = %Artifact{
        id: Ecto.UUID.generate(),
        project_id: project.id,
        user_id: user.id
      }

      changeset = Artifact.changeset(artifact, @valid_artifact_attrs)
      assert changeset.valid?
      assert get_field(changeset, :user_id) == user.id
    end
  end
end
