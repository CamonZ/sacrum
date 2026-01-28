defmodule Sacrum.Repo.WorkflowsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.Workflows
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Schemas.Workflow

  @valid_user_attrs %{
    email: "test@example.com",
    username: "testuser",
    password: "password123"
  }

  @valid_project_attrs %{name: "My Project"}

  @valid_attrs %{
    name: "Default Workflow",
    description: "The default workflow"
  }

  defp create_user do
    {:ok, user} = Users.insert(@valid_user_attrs)
    user
  end

  defp create_project do
    user = create_user()
    {:ok, project} = Projects.insert(user, @valid_project_attrs)
    project
  end

  describe "insert/2" do
    test "creates workflow with valid attrs" do
      project = create_project()
      assert {:ok, %Workflow{} = workflow} = Workflows.insert(project, @valid_attrs)
      assert workflow.name == "Default Workflow"
      assert workflow.description == "The default workflow"
      assert workflow.project_id == project.id
      assert workflow.auto_advance == false
      assert workflow.is_default == false
      assert workflow.metadata == %{}
    end

    test "accepts project_id as binary" do
      project = create_project()
      assert {:ok, %Workflow{}} = Workflows.insert(project.id, @valid_attrs)
    end

    test "rejects missing name" do
      project = create_project()
      assert {:error, changeset} = Workflows.insert(project, %{})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "creates workflow with optional fields" do
      project = create_project()

      attrs =
        Map.merge(@valid_attrs, %{
          auto_advance: true,
          is_default: true,
          display_order: 1,
          metadata: %{"color" => "blue"}
        })

      assert {:ok, %Workflow{} = workflow} = Workflows.insert(project, attrs)
      assert workflow.auto_advance == true
      assert workflow.is_default == true
      assert workflow.display_order == 1
      assert workflow.metadata == %{"color" => "blue"}
    end
  end

  describe "list/1" do
    test "returns workflows for a given project" do
      project = create_project()
      {:ok, w1} = Workflows.insert(project, %{name: "First", display_order: 1})
      {:ok, w2} = Workflows.insert(project, %{name: "Second", display_order: 2})

      workflows = Workflows.list(project)
      assert length(workflows) == 2
      assert Enum.map(workflows, & &1.id) == [w1.id, w2.id]
    end

    test "does not return workflows from other projects" do
      user = create_user()
      {:ok, project1} = Projects.insert(user, %{name: "Project 1"})
      {:ok, project2} = Projects.insert(user, %{name: "Project 2"})
      {:ok, _} = Workflows.insert(project1, %{name: "W1"})
      {:ok, _} = Workflows.insert(project2, %{name: "W2"})

      workflows = Workflows.list(project1)
      assert length(workflows) == 1
      assert hd(workflows).name == "W1"
    end

    test "returns empty list when project has no workflows" do
      project = create_project()
      assert [] = Workflows.list(project)
    end
  end

  describe "get/1" do
    test "returns workflow by ID" do
      project = create_project()
      {:ok, workflow} = Workflows.insert(project, @valid_attrs)
      assert {:ok, found} = Workflows.get(workflow.id)
      assert found.id == workflow.id
    end

    test "returns error when not found" do
      assert {:error, :not_found} = Workflows.get(Ecto.UUID.generate())
    end
  end

  describe "update/2" do
    test "updates name and description" do
      project = create_project()
      {:ok, workflow} = Workflows.insert(project, @valid_attrs)

      assert {:ok, updated} =
               Workflows.update(workflow, %{name: "Updated", description: "New desc"})

      assert updated.name == "Updated"
      assert updated.description == "New desc"
    end

    test "updates auto_advance and is_default" do
      project = create_project()
      {:ok, workflow} = Workflows.insert(project, @valid_attrs)

      assert {:ok, updated} = Workflows.update(workflow, %{auto_advance: true, is_default: true})
      assert updated.auto_advance == true
      assert updated.is_default == true
    end
  end

  describe "delete/1" do
    test "removes the workflow" do
      project = create_project()
      {:ok, workflow} = Workflows.insert(project, @valid_attrs)
      assert {:ok, _} = Workflows.delete(workflow)
      assert {:error, :not_found} = Workflows.get(workflow.id)
    end
  end
end
