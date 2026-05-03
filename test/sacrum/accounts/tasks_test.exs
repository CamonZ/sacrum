defmodule Sacrum.Accounts.TasksTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.Tasks
  alias Sacrum.Accounts.Projects
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Schemas.Task

  @valid_user_attrs %{
    email: "test@example.com",
    username: "testuser",
    password: "password123"
  }

  defp create_user(attrs \\ @valid_user_attrs) do
    {:ok, user} = Users.insert(attrs)
    user
  end

  defp create_project(user) do
    {:ok, project} = Projects.insert(user.id, %{name: "Test Project"})
    project
  end

  describe "insert/3" do
    test "creates task scoped to user_id and project_id" do
      user = create_user()
      project = create_project(user)

      assert {:ok, %Task{} = task} =
               Tasks.insert(user.id, project.id, %{title: "My Task"})

      assert task.user_id == user.id
      assert task.project_id == project.id
      assert task.title == "My Task"
    end

    test "accepts project struct and extracts ids" do
      user = create_user()
      project = create_project(user)

      assert {:ok, %Task{} = task} =
               Tasks.insert(project, %{title: "My Task"})

      assert task.user_id == user.id
      assert task.project_id == project.id
    end

    test "auto-assigns default workflow created by Projects.insert" do
      user = create_user()
      project = create_project(user)

      # Projects.insert auto-creates a default Backlog workflow
      {:ok, task} = Tasks.insert(user.id, project.id, %{title: "Auto WF Task"})

      assert task.workflow_id != nil
      assert task.current_step_id != nil
    end

    test "uses custom default workflow if explicitly set" do
      user = create_user()
      {:ok, project} = Projects.insert(user.id, %{name: "Test Project"})

      # Get the auto-created default Backlog workflow
      workflows = Sacrum.Repo.Workflows.all(conditions: [project_id: project.id])
      backlog = Enum.find(workflows, &(&1.is_default == true))

      # Unset it as default so we can create a new default
      {:ok, _} = Sacrum.Repo.Workflows.update(backlog, %{is_default: false})

      # Create a custom default workflow
      {:ok, custom_workflow} =
        Sacrum.Accounts.Workflows.insert(user.id, project.id, %{
          name: "Custom Default",
          is_default: true
        })

      {:ok, step} =
        Sacrum.Accounts.WorkflowSteps.insert(custom_workflow, %{
          name: "Custom Step",
          step_order: 1
        })

      {:ok, custom_workflow} =
        Sacrum.Repo.Workflows.update(custom_workflow, %{initial_step_id: step.id})

      {:ok, task} = Tasks.insert(user.id, project.id, %{title: "Custom WF Task"})

      # Should use the custom workflow (since it's now the default)
      assert task.workflow_id == custom_workflow.id
      assert task.current_step_id == step.id
    end

    test "auto-created default workflow has initial step" do
      user = create_user()
      project = create_project(user)

      # Projects.insert auto-creates a default workflow with initial step
      {:ok, task} = Tasks.insert(user.id, project.id, %{title: "Task with Step"})

      # Task should be assigned to the auto-created default workflow
      assert task.workflow_id != nil
      assert task.current_step_id != nil
    end
  end

  describe "find/2" do
    test "returns task only if scoped to user" do
      user1 = create_user()
      project1 = create_project(user1)

      user2 =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      project2 = create_project(user2)

      {:ok, task} = Tasks.insert(user1.id, project1.id, %{title: "User1 Task"})
      {:ok, _} = Tasks.insert(user2.id, project2.id, %{title: "User2 Task"})

      # User1 can access their task
      assert {:ok, found} = Tasks.find(user1.id, task.id)
      assert found.id == task.id
      assert found.user_id == user1.id

      # User2 cannot access user1's task
      assert {:error, :not_found} = Tasks.find(user2.id, task.id)
    end

    test "finds task by short_id" do
      user = create_user()
      project = create_project(user)

      {:ok, task} = Tasks.insert(user.id, project.id, %{title: "My Task"})

      assert {:ok, found} = Tasks.find(user.id, task.short_id)
      assert found.id == task.id
    end
  end

  describe "resolve_short_id/3" do
    test "resolves UUID prefix to task within project" do
      user = create_user()
      project = create_project(user)
      {:ok, task} = Tasks.insert(user.id, project.id, %{title: "Resolvable"})

      prefix = String.slice(task.id, 0, 8)
      assert {:ok, found} = Tasks.resolve_short_id(user.id, project.id, prefix)
      assert found.id == task.id
    end

    test "scopes to user" do
      user1 = create_user()
      project1 = create_project(user1)

      user2 =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      {:ok, task} = Tasks.insert(user1.id, project1.id, %{title: "User1 Task"})

      prefix = String.slice(task.id, 0, 8)
      assert {:ok, _} = Tasks.resolve_short_id(user1.id, project1.id, prefix)
      assert {:error, :not_found} = Tasks.resolve_short_id(user2.id, project1.id, prefix)
    end

    test "returns error for invalid prefix" do
      user = create_user()
      project = create_project(user)

      assert {:error, :invalid_prefix} = Tasks.resolve_short_id(user.id, project.id, "zzzzzzzz")
    end
  end

  describe "list_tasks/2" do
    test "returns only tasks scoped to user" do
      user1 = create_user()
      project1 = create_project(user1)

      user2 =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      project2 = create_project(user2)

      {:ok, _} = Tasks.insert(user1.id, project1.id, %{title: "User1 Task"})
      {:ok, _} = Tasks.insert(user2.id, project2.id, %{title: "User2 Task"})

      tasks = Tasks.list_tasks(user1.id)
      assert length(tasks) == 1
      assert hd(tasks).user_id == user1.id
    end

    test "filters by project_id" do
      user = create_user()
      project1 = create_project(user)
      {:ok, project2} = Projects.insert(user.id, %{name: "Project 2"})

      {:ok, _} = Tasks.insert(user.id, project1.id, %{title: "Task 1"})
      {:ok, _} = Tasks.insert(user.id, project2.id, %{title: "Task 2"})

      tasks = Tasks.list_tasks(user.id, conditions: [project_id: project1.id])
      assert length(tasks) == 1
      assert hd(tasks).project_id == project1.id
    end
  end
end
