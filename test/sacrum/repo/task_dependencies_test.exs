defmodule Sacrum.Repo.TaskDependenciesTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Tasks
  alias Sacrum.Repo.TaskDependencies

  @valid_user_attrs %{
    email: "test@example.com",
    username: "testuser",
    password: "password123"
  }

  defp setup_project do
    {:ok, user} = Users.insert(@valid_user_attrs)
    {:ok, project} = Projects.insert(user, %{name: "Test Project"})
    project
  end

  defp create_task(project, title) do
    {:ok, task} = Tasks.insert(project, %{title: title})
    task
  end

  describe "add_dependency/2" do
    test "creates dependency between two tasks in same project" do
      project = setup_project()
      task_a = create_task(project, "A")
      task_b = create_task(project, "B")

      assert {:ok, _} = TaskDependencies.add_dependency(task_a, task_b)
    end

    test "rejects dependency between tasks in different projects" do
      {:ok, user} = Users.insert(@valid_user_attrs)
      {:ok, p1} = Projects.insert(user, %{name: "Project 1"})
      {:ok, p2} = Projects.insert(user, %{name: "Project 2"})
      task_a = create_task(p1, "A")
      task_b = create_task(p2, "B")

      assert {:error, :different_projects} = TaskDependencies.add_dependency(task_a, task_b)
    end

    test "rejects self-dependency" do
      project = setup_project()
      task = create_task(project, "A")

      assert {:error, :self_dependency} = TaskDependencies.add_dependency(task, task)
    end

    test "rejects circular dependency (A->B->A)" do
      project = setup_project()
      task_a = create_task(project, "A")
      task_b = create_task(project, "B")

      {:ok, _} = TaskDependencies.add_dependency(task_a, task_b)
      assert {:error, :circular_dependency} = TaskDependencies.add_dependency(task_b, task_a)
    end

    test "rejects transitive circular dependency (A->B->C->A)" do
      project = setup_project()
      task_a = create_task(project, "A")
      task_b = create_task(project, "B")
      task_c = create_task(project, "C")

      {:ok, _} = TaskDependencies.add_dependency(task_a, task_b)
      {:ok, _} = TaskDependencies.add_dependency(task_b, task_c)
      assert {:error, :circular_dependency} = TaskDependencies.add_dependency(task_c, task_a)
    end
  end

  describe "get_blockers/1" do
    test "returns transitive blockers" do
      project = setup_project()
      task_a = create_task(project, "A")
      task_b = create_task(project, "B")
      task_c = create_task(project, "C")

      # A depends on B, B depends on C
      {:ok, _} = TaskDependencies.add_dependency(task_a, task_b)
      {:ok, _} = TaskDependencies.add_dependency(task_b, task_c)

      blockers = TaskDependencies.get_blockers(task_a)
      blocker_ids = Enum.map(blockers, & &1.id)
      assert task_b.id in blocker_ids
      assert task_c.id in blocker_ids
    end
  end

  describe "remove_dependency/2" do
    test "removes the dependency link" do
      project = setup_project()
      task_a = create_task(project, "A")
      task_b = create_task(project, "B")

      {:ok, _} = TaskDependencies.add_dependency(task_a, task_b)
      {:ok, _} = TaskDependencies.remove_dependency(task_a, task_b)

      assert TaskDependencies.get_direct_blockers(task_a) == []
    end
  end
end
