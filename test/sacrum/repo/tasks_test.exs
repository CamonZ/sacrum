defmodule Sacrum.Repo.TasksTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Tasks
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
    {:ok, project} = Projects.insert(user, %{name: "Test Project"})
    project
  end

  describe "insert/2" do
    test "creates task with valid attrs and auto-generates short_id" do
      user = create_user()
      project = create_project(user)

      {:ok, task} = Tasks.insert(project, %{title: "My Task", description: "A description"})

      assert task.title == "My Task"
      assert task.description == "A description"
      assert task.project_id == project.id
      assert task.short_id =~ ~r/^x[a-f0-9]{6}$/
    end

    test "generates unique 7-char hex short_id prefixed with x" do
      user = create_user()
      project = create_project(user)

      {:ok, t1} = Tasks.insert(project, %{title: "Task 1"})
      {:ok, t2} = Tasks.insert(project, %{title: "Task 2"})

      assert t1.short_id =~ ~r/^x[a-f0-9]{6}$/
      assert t2.short_id =~ ~r/^x[a-f0-9]{6}$/
      assert t1.short_id != t2.short_id
    end

    test "rejects missing title" do
      user = create_user()
      project = create_project(user)

      {:error, changeset} = Tasks.insert(project, %{})
      assert %{title: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "get/1 and get_by_short_id/1" do
    test "get/1 returns task by id" do
      user = create_user()
      project = create_project(user)
      {:ok, task} = Tasks.insert(project, %{title: "Test"})

      assert {:ok, %Task{id: id}} = Tasks.get(task.id)
      assert id == task.id
    end

    test "get_by_short_id/1 returns task by short_id" do
      user = create_user()
      project = create_project(user)
      {:ok, task} = Tasks.insert(project, %{title: "Test"})

      assert {:ok, %Task{short_id: sid}} = Tasks.get_by_short_id(task.short_id)
      assert sid == task.short_id
    end

    test "get/1 returns :not_found for missing id" do
      assert {:error, :not_found} = Tasks.get(Ecto.UUID.generate())
    end
  end

  describe "update/2" do
    test "updates title and description" do
      user = create_user()
      project = create_project(user)
      {:ok, task} = Tasks.insert(project, %{title: "Original"})

      {:ok, updated} = Tasks.update(task, %{title: "Updated", description: "New desc"})
      assert updated.title == "Updated"
      assert updated.description == "New desc"
    end
  end

  describe "delete/1" do
    test "removes the task" do
      user = create_user()
      project = create_project(user)
      {:ok, task} = Tasks.insert(project, %{title: "To Delete"})

      {:ok, _} = Tasks.delete(task)
      assert {:error, :not_found} = Tasks.get(task.id)
    end
  end

  describe "list/1" do
    test "returns tasks for project" do
      user = create_user()
      project = create_project(user)
      {:ok, _} = Tasks.insert(project, %{title: "Task 1"})
      {:ok, _} = Tasks.insert(project, %{title: "Task 2"})

      tasks = Tasks.list(project)
      assert length(tasks) == 2
    end
  end

  describe "list_tasks/1" do
    test "filters by project_id" do
      user = create_user()
      p1 = create_project(user)

      {:ok, p2} =
        Projects.insert(user, %{name: "Other Project"})

      {:ok, _} = Tasks.insert(p1, %{title: "P1 Task"})
      {:ok, _} = Tasks.insert(p2, %{title: "P2 Task"})

      tasks = Tasks.list_tasks(project_id: p1.id)
      assert length(tasks) == 1
      assert hd(tasks).title == "P1 Task"
    end

    test "filters by level" do
      user = create_user()
      project = create_project(user)
      {:ok, _} = Tasks.insert(project, %{title: "Ticket", level: "ticket"})
      {:ok, _} = Tasks.insert(project, %{title: "Task", level: "task"})

      tasks = Tasks.list_tasks(project_id: project.id, level: "ticket")
      assert length(tasks) == 1
      assert hd(tasks).title == "Ticket"
    end

    test "returns all tasks with no filters" do
      user = create_user()
      project = create_project(user)
      {:ok, _} = Tasks.insert(project, %{title: "Task 1"})
      {:ok, _} = Tasks.insert(project, %{title: "Task 2"})

      tasks = Tasks.list_tasks(project_id: project.id)
      assert length(tasks) == 2
    end
  end
end
