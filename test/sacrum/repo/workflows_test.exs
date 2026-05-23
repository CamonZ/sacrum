defmodule Sacrum.Repo.WorkflowsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.Workflows
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.TaskRuns
  alias Sacrum.Repo.Tasks
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.WorkflowSteps
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

  defp create_user(attrs \\ %{}) do
    {:ok, user} = @valid_user_attrs |> Map.merge(attrs) |> Users.insert()
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
          name: "Custom Workflow",
          is_default: false,
          display_order: 1,
          metadata: %{"color" => "blue"}
        })

      assert {:ok, %Workflow{} = workflow} = Workflows.insert(project, attrs)
      assert workflow.is_default == false
      assert workflow.display_order == 1
      assert workflow.metadata == %{"color" => "blue"}
    end

    test "rejects creating second default workflow in same project" do
      project = create_project()
      # A default workflow (Backlog) is auto-created with the project

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

      # Both projects auto-create a Backlog default workflow, so verify they are separate
      workflows1 = Workflows.all(conditions: [project_id: project1.id])
      workflows2 = Workflows.all(conditions: [project_id: project2.id])

      assert Enum.any?(workflows1, &(&1.is_default == true))
      assert Enum.any?(workflows2, &(&1.is_default == true))

      # And the default workflows are separate for each project
      default1 = Enum.find(workflows1, &(&1.is_default == true))
      default2 = Enum.find(workflows2, &(&1.is_default == true))
      assert default1.project_id != default2.project_id
    end
  end

  describe "all/1" do
    test "returns workflows for a given project" do
      project = create_project()
      {:ok, _w1} = Workflows.insert(project, %{name: "First", display_order: 1})
      {:ok, _w2} = Workflows.insert(project, %{name: "Second", display_order: 2})

      workflows =
        Workflows.all(
          conditions: [project_id: project.id],
          order_by: [asc: :display_order, asc: :inserted_at]
        )

      assert length(workflows) == 3
      names = Enum.map(workflows, & &1.name)
      assert "Backlog" in names
      assert "First" in names
      assert "Second" in names
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

      assert length(workflows) == 2
      names = Enum.map(workflows, & &1.name)
      assert "Backlog" in names
      assert "W1" in names
      assert "W2" not in names
    end

    test "returns at least the auto-created Backlog workflow for new projects" do
      project = create_project()

      workflows =
        Workflows.all(
          conditions: [project_id: project.id],
          order_by: [asc: :display_order, asc: :inserted_at]
        )

      assert length(workflows) >= 1
      assert hd(workflows).name == "Backlog"
      assert hd(workflows).is_default == true
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

    test "ignores stale auto_advance attrs" do
      project = create_project()
      {:ok, workflow} = Workflows.insert(project, Map.put(@valid_attrs, :auto_advance, true))

      refute Map.has_key?(workflow, :auto_advance)

      assert {:ok, updated} = Workflows.update(workflow, %{auto_advance: true, name: "Updated"})
      assert updated.name == "Updated"
      refute Map.has_key?(updated, :auto_advance)
    end

    test "rejects updating workflow to default when another default exists" do
      project = create_project()
      # A default Backlog workflow already exists from project creation

      {:ok, second_workflow} =
        Workflows.insert(project, Map.merge(@valid_attrs, %{name: "Second"}))

      assert {:error, changeset} =
               Workflows.update(second_workflow, %{is_default: true})

      assert %{is_default: [_error]} = errors_on(changeset)
    end

    test "allows setting workflow as default by unsetting other default first" do
      project = create_project()
      # Get the auto-created default workflow (Backlog)
      workflows = Workflows.all(conditions: [project_id: project.id])
      existing_default = Enum.find(workflows, &(&1.is_default == true))

      {:ok, second_workflow} =
        Workflows.insert(project, Map.merge(@valid_attrs, %{name: "Second"}))

      assert {:ok, _updated_first} = Workflows.update(existing_default, %{is_default: false})

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

  describe "pipeline_summary/2" do
    test "scopes task and active run counts by user, project, and step" do
      project = create_project()
      suffix = System.unique_integer([:positive])

      other_user =
        create_user(%{
          email: "pipeline-other#{suffix}@example.com",
          username: "pipelineother#{suffix}"
        })

      {:ok, other_project} =
        Sacrum.Repo.Projects.insert(other_user.id, %{name: "Other Pipeline Project"})

      {:ok, workflow} = Workflows.insert(project, %{name: "Pipeline"})
      {:ok, step} = WorkflowSteps.insert(workflow, %{name: "Review", step_order: 1})

      {:ok, other_workflow} = Workflows.insert(other_project, %{name: "Pipeline"})

      {:ok, other_step} =
        WorkflowSteps.insert(other_workflow, %{name: "Review", step_order: 1})

      {:ok, ticket} =
        Tasks.insert(project.id, project.user_id, %{
          title: "Visible ticket",
          level: "ticket",
          workflow_id: workflow.id,
          current_step_id: step.id
        })

      {:ok, other_task} =
        Tasks.insert(other_project.id, other_user.id, %{
          title: "Other user task",
          level: "epic",
          workflow_id: other_workflow.id,
          current_step_id: other_step.id
        })

      {:ok, _active_run} =
        TaskRuns.insert(project.user_id, project.id, ticket.id, %{status: :queued})

      {:ok, _other_run} =
        TaskRuns.insert(other_user.id, other_project.id, other_task.id, %{status: :waiting})

      {:ok, _workflows, %{pipeline_counts_by_step_id: counts_by_step}} =
        Workflows.pipeline_summary(project.user_id, project.id)

      assert counts_by_step[step.id] == %{ticket: 1, active: 1}
    end
  end
end
