defmodule Sacrum.Repo.ProjectsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Schemas.Project

  @valid_user_attrs %{
    email: "test@example.com",
    username: "testuser",
    password: "password123"
  }

  @valid_attrs %{
    name: "My Project",
    description: "A test project"
  }

  defp create_user(attrs \\ @valid_user_attrs) do
    {:ok, user} = Users.insert(attrs)
    user
  end

  defp create_user2 do
    create_user(%{email: "other@example.com", username: "otheruser", password: "password123"})
  end

  describe "insert/2" do
    test "creates project with valid attrs and auto-generates slug from name" do
      user = create_user()
      assert {:ok, %Project{} = project} = Projects.insert(user, @valid_attrs)
      assert project.name == "My Project"
      assert project.slug == "my-project"
      assert project.description == "A test project"
      assert project.user_id == user.id
    end

    test "with explicit slug uses the provided slug" do
      user = create_user()
      attrs = Map.put(@valid_attrs, :slug, "custom-slug")
      assert {:ok, %Project{} = project} = Projects.insert(user, attrs)
      assert project.slug == "custom-slug"
    end

    test "rejects invalid slug format (uppercase)" do
      user = create_user()
      attrs = Map.put(@valid_attrs, :slug, "Invalid-Slug")
      assert {:error, changeset} = Projects.insert(user, attrs)
      assert %{slug: [_]} = errors_on(changeset)
    end

    test "rejects invalid slug format (spaces)" do
      user = create_user()
      attrs = Map.put(@valid_attrs, :slug, "has spaces")
      assert {:error, changeset} = Projects.insert(user, attrs)
      assert %{slug: [_]} = errors_on(changeset)
    end

    test "rejects invalid slug format (special chars)" do
      user = create_user()
      attrs = Map.put(@valid_attrs, :slug, "has_underscore")
      assert {:error, changeset} = Projects.insert(user, attrs)
      assert %{slug: [_]} = errors_on(changeset)
    end

    test "rejects duplicate slug for same user" do
      user = create_user()
      {:ok, _} = Projects.insert(user, @valid_attrs)
      assert {:error, changeset} = Projects.insert(user, @valid_attrs)
      assert %{slug: ["has already been taken for this user"]} = errors_on(changeset)
    end

    test "allows same slug for different users" do
      user1 = create_user()
      user2 = create_user2()
      assert {:ok, _} = Projects.insert(user1, @valid_attrs)
      assert {:ok, _} = Projects.insert(user2, @valid_attrs)
    end

    test "returns error with missing name" do
      user = create_user()
      assert {:error, changeset} = Projects.insert(user, %{})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "accepts user_id as binary" do
      user = create_user()
      assert {:ok, %Project{}} = Projects.insert(user.id, @valid_attrs)
    end
  end

  describe "all/1" do
    test "returns only projects belonging to the given user" do
      user1 = create_user()
      user2 = create_user2()
      {:ok, project1} = Projects.insert(user1, @valid_attrs)
      {:ok, _project2} = Projects.insert(user2, %{name: "Other Project"})

      projects = Projects.all(conditions: [user_id: user1.id], order_by: [asc: :inserted_at])
      assert length(projects) == 1
      assert hd(projects).id == project1.id
    end

    test "returns empty list when user has no projects" do
      user = create_user()
      assert [] = Projects.all(conditions: [user_id: user.id], order_by: [asc: :inserted_at])
    end
  end

  describe "get/1" do
    test "returns project by ID" do
      user = create_user()
      {:ok, project} = Projects.insert(user, @valid_attrs)
      assert {:ok, found} = Projects.get(project.id)
      assert found.id == project.id
    end

    test "returns error when not found" do
      assert {:error, :not_found} = Projects.get(Ecto.UUID.generate())
    end
  end

  describe "get_by/1" do
    test "returns project by clauses" do
      user = create_user()
      {:ok, project} = Projects.insert(user, @valid_attrs)
      assert {:ok, found} = Projects.get_by(user_id: user.id, slug: "my-project")
      assert found.id == project.id
    end
  end

  describe "update/2" do
    test "updates name and description" do
      user = create_user()
      {:ok, project} = Projects.insert(user, @valid_attrs)

      assert {:ok, updated} =
               Projects.update(project, %{name: "Updated", description: "New desc"})

      assert updated.name == "Updated"
      assert updated.description == "New desc"
    end

    test "updates slug with valid format" do
      user = create_user()
      {:ok, project} = Projects.insert(user, @valid_attrs)
      assert {:ok, updated} = Projects.update(project, %{slug: "new-slug"})
      assert updated.slug == "new-slug"
    end

    test "rejects invalid slug on update" do
      user = create_user()
      {:ok, project} = Projects.insert(user, @valid_attrs)
      assert {:error, changeset} = Projects.update(project, %{slug: "BAD SLUG"})
      assert %{slug: [_]} = errors_on(changeset)
    end
  end

  describe "delete/1" do
    test "removes the project" do
      user = create_user()
      {:ok, project} = Projects.insert(user, @valid_attrs)
      assert {:ok, _} = Projects.delete(project)
      assert {:error, :not_found} = Projects.get(project.id)
    end
  end
end
