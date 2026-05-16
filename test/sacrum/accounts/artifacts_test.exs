defmodule Sacrum.Accounts.ArtifactsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.Artifacts
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.ArtifactLinks

  @valid_user_attrs %{
    email: "test@example.com",
    username: "testuser",
    password: "password123"
  }

  @valid_project_attrs %{
    name: "Test Project"
  }

  @valid_artifact_attrs %{
    name: "Test Artifact",
    description: "A test artifact",
    artifact_type: "file",
    url: "https://example.com/artifact",
    visibility: "public"
  }

  defp create_user(attrs \\ @valid_user_attrs) do
    {:ok, user} = Users.insert(attrs)
    user
  end

  defp create_project(user, attrs \\ @valid_project_attrs) do
    {:ok, project} = Projects.insert(user, attrs)
    project
  end

  describe "create/3" do
    test "creates artifact scoped to user and project" do
      user = create_user()
      project = create_project(user)

      {:ok, artifact} = Artifacts.create(user.id, project.id, @valid_artifact_attrs)

      assert artifact.name == "Test Artifact"
      assert artifact.project_id == project.id
      assert artifact.user_id == user.id
      assert artifact.visibility == "public"
    end

    test "validates that project belongs to user" do
      user1 = create_user()

      user2 =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      project = create_project(user1)

      # User2 cannot create artifacts in user1's project
      assert {:error, :unauthorized} =
               Artifacts.create(user2.id, project.id, @valid_artifact_attrs)
    end

    test "rejects invalid user_id" do
      fake_user_id = Ecto.UUID.generate()
      fake_project_id = Ecto.UUID.generate()

      assert {:error, _} = Artifacts.create(fake_user_id, fake_project_id, @valid_artifact_attrs)
    end

    test "rejects invalid project_id" do
      user = create_user()
      fake_project_id = Ecto.UUID.generate()

      assert {:error, _} = Artifacts.create(user.id, fake_project_id, @valid_artifact_attrs)
    end
  end

  describe "get_for_project/3" do
    test "returns artifact only if user is the owner" do
      user1 = create_user()

      user2 =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      project = create_project(user1)

      {:ok, artifact} = Artifacts.create(user1.id, project.id, @valid_artifact_attrs)

      # User1 can access their artifact
      assert {:ok, found} = Artifacts.get_for_project(user1.id, artifact.id, project.id)
      assert found.id == artifact.id

      # User2 cannot access user1's artifact
      assert {:error, :not_found} = Artifacts.get_for_project(user2.id, artifact.id, project.id)
    end

    test "filters to public artifacts by default" do
      user = create_user()
      project = create_project(user)

      {:ok, _artifact} =
        Artifacts.create(user.id, project.id, %{
          name: "Internal Artifact",
          visibility: "internal"
        })

      artifacts = Artifacts.list_by_project(user.id, project.id)
      assert Enum.all?(artifacts, fn a -> a.visibility == "public" end)
    end

    test "can retrieve internal artifacts with internal: true opt" do
      user = create_user()
      project = create_project(user)

      {:ok, artifact} =
        Artifacts.create(user.id, project.id, %{
          name: "Internal Artifact",
          visibility: "internal"
        })

      assert {:ok, found} =
               Artifacts.get_for_project(user.id, artifact.id, project.id, internal: true)

      assert found.id == artifact.id
      assert found.visibility == "internal"
    end
  end

  describe "list_by_project/2" do
    test "returns only public artifacts for the user's project" do
      user = create_user()
      project = create_project(user)

      {:ok, public_artifact} =
        Artifacts.create(user.id, project.id, %{
          name: "Public Artifact",
          visibility: "public"
        })

      {:ok, _internal_artifact} =
        Artifacts.create(user.id, project.id, %{
          name: "Internal Artifact",
          visibility: "internal"
        })

      artifacts = Artifacts.list_by_project(user.id, project.id)

      assert length(artifacts) == 1
      assert hd(artifacts).id == public_artifact.id
      assert Enum.all?(artifacts, fn a -> a.visibility == "public" end)
    end

    test "scopes to user_id" do
      user1 = create_user()

      user2 =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      project1 = create_project(user1)
      project2 = create_project(user2)

      {:ok, _} = Artifacts.create(user1.id, project1.id, %{name: "User1 Artifact"})
      {:ok, _} = Artifacts.create(user2.id, project2.id, %{name: "User2 Artifact"})

      artifacts = Artifacts.list_by_project(user1.id, project1.id)
      assert length(artifacts) == 1
      assert hd(artifacts).user_id == user1.id
    end

    test "returns empty list when no public artifacts exist" do
      user = create_user()
      project = create_project(user)

      {:ok, _} =
        Artifacts.create(user.id, project.id, %{
          name: "Internal Artifact",
          visibility: "internal"
        })

      artifacts = Artifacts.list_by_project(user.id, project.id)
      assert artifacts == []
    end
  end

  describe "list_for_subject/4" do
    test "returns public artifacts linked to a subject within user's project" do
      user = create_user()
      project = create_project(user)

      {:ok, artifact1} =
        Artifacts.create(user.id, project.id, %{
          name: "Public Artifact 1",
          visibility: "public"
        })

      {:ok, artifact2} =
        Artifacts.create(user.id, project.id, %{
          name: "Public Artifact 2",
          visibility: "public"
        })

      subject_id = Ecto.UUID.generate()
      subject_type = "task"

      {:ok, _} =
        ArtifactLinks.add_link(%{
          artifact_id: artifact1.id,
          subject_id: subject_id,
          subject_type: subject_type,
          project_id: project.id
        })

      {:ok, _} =
        ArtifactLinks.add_link(%{
          artifact_id: artifact2.id,
          subject_id: subject_id,
          subject_type: subject_type,
          project_id: project.id
        })

      artifacts = Artifacts.list_for_subject(user.id, subject_type, subject_id, project.id)

      assert length(artifacts) == 2
      assert Enum.all?(artifacts, fn a -> a.visibility == "public" end)
    end

    test "filters out internal artifacts from list_for_subject" do
      user = create_user()
      project = create_project(user)

      {:ok, public_artifact} =
        Artifacts.create(user.id, project.id, %{
          name: "Public Artifact",
          visibility: "public"
        })

      {:ok, internal_artifact} =
        Artifacts.create(user.id, project.id, %{
          name: "Internal Artifact",
          visibility: "internal"
        })

      subject_id = Ecto.UUID.generate()
      subject_type = "task"

      {:ok, _} =
        ArtifactLinks.add_link(%{
          artifact_id: public_artifact.id,
          subject_id: subject_id,
          subject_type: subject_type,
          project_id: project.id
        })

      {:ok, _} =
        ArtifactLinks.add_link(%{
          artifact_id: internal_artifact.id,
          subject_id: subject_id,
          subject_type: subject_type,
          project_id: project.id
        })

      artifacts = Artifacts.list_for_subject(user.id, subject_type, subject_id, project.id)

      # Should only include public artifacts
      assert length(artifacts) == 1
      assert hd(artifacts).visibility == "public"
    end

    test "scopes to user_id and project_id" do
      user1 = create_user()

      user2 =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      project1 = create_project(user1)
      project2 = create_project(user2)

      {:ok, artifact1} =
        Artifacts.create(user1.id, project1.id, %{
          name: "User1 Artifact",
          visibility: "public"
        })

      {:ok, artifact2} =
        Artifacts.create(user2.id, project2.id, %{
          name: "User2 Artifact",
          visibility: "public"
        })

      subject_id = Ecto.UUID.generate()

      {:ok, _} =
        ArtifactLinks.add_link(%{
          artifact_id: artifact1.id,
          subject_id: subject_id,
          subject_type: "task",
          project_id: project1.id
        })

      {:ok, _} =
        ArtifactLinks.add_link(%{
          artifact_id: artifact2.id,
          subject_id: subject_id,
          subject_type: "task",
          project_id: project2.id
        })

      artifacts = Artifacts.list_for_subject(user1.id, "task", subject_id, project1.id)

      # Should only see user1's artifact from project1
      assert length(artifacts) == 1
      assert hd(artifacts).user_id == user1.id
      assert hd(artifacts).project_id == project1.id
    end

    test "returns empty list when no public artifacts are linked" do
      user = create_user()
      project = create_project(user)

      subject_id = Ecto.UUID.generate()

      artifacts = Artifacts.list_for_subject(user.id, "task", subject_id, project.id)
      assert artifacts == []
    end
  end

  describe "add_link/4" do
    test "links artifact to subject through accounts layer" do
      user = create_user()
      project = create_project(user)

      {:ok, artifact} = Artifacts.create(user.id, project.id, @valid_artifact_attrs)

      subject_id = Ecto.UUID.generate()
      subject_type = "task"

      assert {:ok, _link} =
               Artifacts.add_link(user.id, artifact.id, subject_type, subject_id, project.id)
    end

    test "validates that artifact belongs to the user's project" do
      user1 = create_user()

      user2 =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      project1 = create_project(user1)
      project2 = create_project(user2)

      {:ok, artifact} = Artifacts.create(user1.id, project1.id, @valid_artifact_attrs)

      subject_id = Ecto.UUID.generate()

      # User1 can link their own artifact
      assert {:ok, _link} =
               Artifacts.add_link(user1.id, artifact.id, "task", subject_id, project1.id)

      # User2 cannot link user1's artifact (different project)
      assert {:error, :unauthorized} =
               Artifacts.add_link(user2.id, artifact.id, "task", subject_id, project2.id)
    end

    test "prevents cross-project links" do
      user = create_user()
      project1 = create_project(user)
      project2 = create_project(user, %{name: "Other Project"})

      {:ok, artifact} = Artifacts.create(user.id, project1.id, @valid_artifact_attrs)

      subject_id = Ecto.UUID.generate()

      # Try to link artifact from project1 to subject in project2
      assert {:error, :unauthorized} =
               Artifacts.add_link(user.id, artifact.id, "task", subject_id, project2.id)
    end
  end

  describe "update/3" do
    test "updates artifact for user" do
      user = create_user()
      project = create_project(user)

      {:ok, artifact} = Artifacts.create(user.id, project.id, @valid_artifact_attrs)

      {:ok, updated} = Artifacts.update(user.id, artifact.id, project.id, %{name: "Updated Name"})
      assert updated.name == "Updated Name"
    end

    test "prevents user from updating another user's artifact" do
      user1 = create_user()

      user2 =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      project = create_project(user1)

      {:ok, artifact} = Artifacts.create(user1.id, project.id, @valid_artifact_attrs)

      # User2 cannot update user1's artifact
      assert {:error, :unauthorized} =
               Artifacts.update(user2.id, artifact.id, project.id, %{name: "New Name"})
    end
  end

  describe "delete/3" do
    test "deletes artifact for user" do
      user = create_user()
      project = create_project(user)

      {:ok, artifact} = Artifacts.create(user.id, project.id, @valid_artifact_attrs)

      assert {:ok, _} = Artifacts.delete(user.id, artifact.id, project.id)

      # Artifact should no longer be accessible
      assert {:error, :not_found} = Artifacts.get_for_project(user.id, artifact.id, project.id)
    end

    test "prevents user from deleting another user's artifact" do
      user1 = create_user()

      user2 =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      project = create_project(user1)

      {:ok, artifact} = Artifacts.create(user1.id, project.id, @valid_artifact_attrs)

      # User2 cannot delete user1's artifact
      assert {:error, :unauthorized} = Artifacts.delete(user2.id, artifact.id, project.id)
    end
  end

  describe "visibility enforcement in accounts layer" do
    test "all read operations default to public visibility" do
      user = create_user()
      project = create_project(user)

      {:ok, _public} =
        Artifacts.create(user.id, project.id, %{
          name: "Public",
          visibility: "public"
        })

      {:ok, _internal} =
        Artifacts.create(user.id, project.id, %{
          name: "Internal",
          visibility: "internal"
        })

      # list_by_project defaults to public
      artifacts = Artifacts.list_by_project(user.id, project.id)
      assert length(artifacts) == 1

      # list_for_subject defaults to public
      subject_id = Ecto.UUID.generate()
      artifacts = Artifacts.list_for_subject(user.id, "task", subject_id, project.id)
      # No links, so empty
      assert length(artifacts) == 0

      # Attempting to get non-public artifact without flag
      {:ok, internal} =
        Artifacts.create(user.id, project.id, %{
          name: "Another Internal",
          visibility: "internal"
        })

      # Should not find internal artifact in public query
      assert {:error, :not_found} = Artifacts.get_for_project(user.id, internal.id, project.id)

      # Should find it with internal: true flag
      assert {:ok, found} =
               Artifacts.get_for_project(user.id, internal.id, project.id, internal: true)

      assert found.visibility == "internal"
    end
  end
end
