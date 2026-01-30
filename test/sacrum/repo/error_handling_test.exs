defmodule Sacrum.Repo.ErrorHandlingTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.Users
  alias Sacrum.Repo.ApiTokens
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Workflows
  alias Sacrum.Repo.WorkflowSteps
  alias Sacrum.Repo.Tasks
  alias Sacrum.Repo.TaskSections
  alias Sacrum.Repo.StepTransitions
  alias Sacrum.Repo.SessionLogs
  alias Sacrum.Repo.StepExecutions
  alias Sacrum.Repo.CodeRefs
  alias Sacrum.Repo.TaskDependencies
  alias Sacrum.Repo.TaskHierarchy
  alias Sacrum.Repo.WorkflowTransitions

  @valid_user_attrs %{
    email: "test@example.com",
    username: "testuser",
    password: "password123"
  }

  describe "get/1 error contract - returns {:error, :not_found} for non-existent IDs" do
    test "Users.get/1 returns :not_found" do
      assert {:error, :not_found} = Users.get(Ecto.UUID.generate())
    end

    test "ApiTokens.get/1 returns :not_found" do
      assert {:error, :not_found} = ApiTokens.get(Ecto.UUID.generate())
    end

    test "Projects.get/1 returns :not_found" do
      assert {:error, :not_found} = Projects.get(Ecto.UUID.generate())
    end

    test "Workflows.get/1 returns :not_found" do
      assert {:error, :not_found} = Workflows.get(Ecto.UUID.generate())
    end

    test "WorkflowSteps.get/1 returns :not_found" do
      assert {:error, :not_found} = WorkflowSteps.get(Ecto.UUID.generate())
    end

    test "Tasks.get/1 returns :not_found" do
      assert {:error, :not_found} = Tasks.get(Ecto.UUID.generate())
    end

    test "TaskSections.get/1 returns :not_found" do
      assert {:error, :not_found} = TaskSections.get(Ecto.UUID.generate())
    end

    test "StepTransitions.get/1 returns :not_found" do
      assert {:error, :not_found} = StepTransitions.get(Ecto.UUID.generate())
    end

    test "SessionLogs.get/1 returns :not_found" do
      assert {:error, :not_found} = SessionLogs.get(Ecto.UUID.generate())
    end

    test "StepExecutions.get/1 returns :not_found" do
      assert {:error, :not_found} = StepExecutions.get(Ecto.UUID.generate())
    end

    test "CodeRefs.get/1 returns :not_found" do
      assert {:error, :not_found} = CodeRefs.get(Ecto.UUID.generate())
    end

    test "WorkflowTransitions.get/1 returns :not_found" do
      assert {:error, :not_found} = WorkflowTransitions.get(Ecto.UUID.generate())
    end
  end

  describe "insert/1 error contract - returns {:error, changeset} for validation errors" do
    test "Users.insert/1 returns changeset for empty attrs" do
      assert {:error, changeset} = Users.insert(%{})
      assert %Ecto.Changeset{} = changeset
      assert changeset.errors != []
    end

    test "ApiTokens.insert/1 returns changeset for empty attrs" do
      {:ok, _user} = Users.insert(@valid_user_attrs)

      assert {:error, changeset} = ApiTokens.insert(%{})
      assert %Ecto.Changeset{} = changeset
      assert changeset.errors != []
    end

    test "Projects.insert/2 returns changeset for empty attrs" do
      {:ok, user} = Users.insert(@valid_user_attrs)

      assert {:error, changeset} = Projects.insert(user, %{})
      assert %Ecto.Changeset{} = changeset
      assert changeset.errors != []
    end

    test "TaskSections.insert/2 returns changeset for empty attrs" do
      {:ok, user} = Users.insert(@valid_user_attrs)
      {:ok, project} = Projects.insert(user, %{name: "Test Project"})
      {:ok, task} = Tasks.insert(project, %{title: "Test Task"})

      assert {:error, changeset} = TaskSections.insert(task, %{})
      assert %Ecto.Changeset{} = changeset
      assert changeset.errors != []
    end
  end

  describe "get/1 returns {:ok, record} for existing records" do
    test "Users.get/1 returns ok tuple for existing user" do
      {:ok, user} = Users.insert(@valid_user_attrs)

      assert {:ok, found} = Users.get(user.id)
      assert found.id == user.id
      assert found.email == "test@example.com"
    end

    test "Tasks.get/1 returns ok tuple and preloads sections" do
      {:ok, user} = Users.insert(@valid_user_attrs)
      {:ok, project} = Projects.insert(user, %{name: "Test Project"})
      {:ok, task} = Tasks.insert(project, %{title: "Test Task"})

      assert {:ok, found} = Tasks.get(task.id)
      assert found.id == task.id
      assert found.sections != nil
    end
  end

  describe "update/2 error contract - returns {:error, changeset} for validation errors" do
    test "Users.update/2 returns changeset for invalid email" do
      {:ok, user} = Users.insert(@valid_user_attrs)

      assert {:error, changeset} = Users.update(user, %{email: "invalid"})
      assert %Ecto.Changeset{} = changeset
      assert changeset.errors != []
    end

    test "Tasks.update/2 succeeds with valid data" do
      {:ok, user} = Users.insert(@valid_user_attrs)
      {:ok, project} = Projects.insert(user, %{name: "Test Project"})
      {:ok, task} = Tasks.insert(project, %{title: "Test Task"})

      # Attempt to update with valid data
      assert {:ok, updated} = Tasks.update(task, %{title: "Updated Task"})
      assert updated.title == "Updated Task"
    end
  end

  describe "domain-specific error atoms" do
    test "TaskDependencies.add_dependency/2 returns :self_dependency" do
      {:ok, user} = Users.insert(@valid_user_attrs)
      {:ok, project} = Projects.insert(user, %{name: "Test Project"})
      {:ok, task} = Tasks.insert(project, %{title: "Test Task"})

      assert {:error, :self_dependency} = TaskDependencies.add_dependency(task, task)
    end

    test "TaskDependencies.add_dependency/2 returns :different_projects" do
      {:ok, user1} = Users.insert(@valid_user_attrs)

      {:ok, user2} =
        Users.insert(%{
          @valid_user_attrs
          | email: "other@example.com",
            username: "otheruser"
        })

      {:ok, project1} = Projects.insert(user1, %{name: "Project 1"})
      {:ok, project2} = Projects.insert(user2, %{name: "Project 2"})
      {:ok, task1} = Tasks.insert(project1, %{title: "Task 1"})
      {:ok, task2} = Tasks.insert(project2, %{title: "Task 2"})

      assert {:error, :different_projects} = TaskDependencies.add_dependency(task1, task2)
    end

    test "TaskDependencies.add_dependency/2 returns :circular_dependency" do
      {:ok, user} = Users.insert(@valid_user_attrs)
      {:ok, project} = Projects.insert(user, %{name: "Test Project"})
      {:ok, task1} = Tasks.insert(project, %{title: "Task 1"})
      {:ok, task2} = Tasks.insert(project, %{title: "Task 2"})

      # Create a dependency chain: task1 -> task2
      {:ok, _} = TaskDependencies.add_dependency(task1, task2)

      # Attempting to add task2 -> task1 should create a cycle
      assert {:error, :circular_dependency} = TaskDependencies.add_dependency(task2, task1)
    end

    test "TaskDependencies.remove_dependency/2 returns :not_found for non-existent dependency" do
      {:ok, user} = Users.insert(@valid_user_attrs)
      {:ok, project} = Projects.insert(user, %{name: "Test Project"})
      {:ok, task1} = Tasks.insert(project, %{title: "Task 1"})
      {:ok, task2} = Tasks.insert(project, %{title: "Task 2"})

      # No dependency exists between task1 and task2
      assert {:error, :not_found} = TaskDependencies.remove_dependency(task1, task2)
    end

    test "TaskHierarchy.remove_parent/1 returns :not_found when no parent exists" do
      {:ok, user} = Users.insert(@valid_user_attrs)
      {:ok, project} = Projects.insert(user, %{name: "Test Project"})
      {:ok, task} = Tasks.insert(project, %{title: "Task"})

      # Task has no parent
      assert {:error, :not_found} = TaskHierarchy.remove_parent(task)
    end

    test "TaskHierarchy.get_parent/1 returns :not_found when no parent exists" do
      {:ok, user} = Users.insert(@valid_user_attrs)
      {:ok, project} = Projects.insert(user, %{name: "Test Project"})
      {:ok, task} = Tasks.insert(project, %{title: "Task"})

      # Task has no parent
      assert {:error, :not_found} = TaskHierarchy.get_parent(task)
    end
  end
end
