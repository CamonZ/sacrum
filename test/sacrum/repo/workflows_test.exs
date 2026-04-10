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
      assert {:ok, %Workflow{}} = Workflows.insert(project.id, project.user_id, @valid_attrs)
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

    test "rejects creating second default workflow in same project" do
      project = create_project()

      attrs_default = Map.merge(@valid_attrs, %{is_default: true})
      assert {:ok, _first_default} = Workflows.insert(project, attrs_default)

      attrs_second_default =
        Map.merge(@valid_attrs, %{name: "Second Default", is_default: true})

      assert {:error, changeset} = Workflows.insert(project, attrs_second_default)
      assert %{is_default: [_error]} = errors_on(changeset)
    end

    test "allows creating multiple non-default workflows in same project" do
      project = create_project()

      assert {:ok, _w1} = Workflows.insert(project, @valid_attrs)

      assert {:ok, _w2} =
               Workflows.insert(project, Map.merge(@valid_attrs, %{name: "Another"}))
    end

    test "allows creating default workflow in different projects" do
      user = create_user()
      {:ok, project1} = Projects.insert(user, %{name: "Project 1"})
      {:ok, project2} = Projects.insert(user, %{name: "Project 2"})

      attrs_default = Map.merge(@valid_attrs, %{is_default: true})
      assert {:ok, _w1} = Workflows.insert(project1, attrs_default)
      assert {:ok, _w2} = Workflows.insert(project2, attrs_default)
    end
  end

  describe "all/1" do
    test "returns workflows for a given project" do
      project = create_project()
      {:ok, w1} = Workflows.insert(project, %{name: "First", display_order: 1})
      {:ok, w2} = Workflows.insert(project, %{name: "Second", display_order: 2})

      workflows =
        Workflows.all(
          conditions: [project_id: project.id],
          order_by: [asc: :display_order, asc: :inserted_at]
        )

      assert length(workflows) == 2
      assert Enum.map(workflows, & &1.id) == [w1.id, w2.id]
    end

    test "does not return workflows from other projects" do
      user = create_user()
      {:ok, project1} = Projects.insert(user, %{name: "Project 1"})
      {:ok, project2} = Projects.insert(user, %{name: "Project 2"})
      {:ok, _} = Workflows.insert(project1, %{name: "W1"})
      {:ok, _} = Workflows.insert(project2, %{name: "W2"})

      workflows =
        Workflows.all(
          conditions: [project_id: project1.id],
          order_by: [asc: :display_order, asc: :inserted_at]
        )

      assert length(workflows) == 1
      assert hd(workflows).name == "W1"
    end

    test "returns empty list when project has no workflows" do
      project = create_project()

      assert [] =
               Workflows.all(
                 conditions: [project_id: project.id],
                 order_by: [asc: :display_order, asc: :inserted_at]
               )
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

    test "rejects updating workflow to default when another default exists" do
      project = create_project()

      {:ok, _first_workflow} =
        Workflows.insert(project, Map.merge(@valid_attrs, %{name: "First", is_default: true}))

      {:ok, second_workflow} =
        Workflows.insert(project, Map.merge(@valid_attrs, %{name: "Second"}))

      assert {:error, changeset} =
               Workflows.update(second_workflow, %{is_default: true})

      assert %{is_default: [_error]} = errors_on(changeset)
    end

    test "allows setting workflow as default by unsetting other default first" do
      project = create_project()

      {:ok, first_workflow} =
        Workflows.insert(project, Map.merge(@valid_attrs, %{name: "First", is_default: true}))

      {:ok, second_workflow} =
        Workflows.insert(project, Map.merge(@valid_attrs, %{name: "Second"}))

      assert {:ok, _updated_first} = Workflows.update(first_workflow, %{is_default: false})

      assert {:ok, updated_second} = Workflows.update(second_workflow, %{is_default: true})
      assert updated_second.is_default == true
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
