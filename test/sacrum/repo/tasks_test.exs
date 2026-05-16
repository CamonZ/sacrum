defmodule Sacrum.Repo.TasksTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Tasks
  alias Sacrum.Repo.Workflows
  alias Sacrum.Repo.WorkflowSteps
  alias Sacrum.Repo.StepTransitions
  alias Sacrum.Repo.TaskWorkflows
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

    test "defaults level to \"task\" when not provided" do
      user = create_user()
      project = create_project(user)

      {:ok, task} = Tasks.insert(project, %{title: "Default Level"})

      assert task.level == "task"

      {:ok, reloaded} = Tasks.get(task.id)
      assert reloaded.level == "task"
    end

    for level <- ["epic", "ticket", "task"] do
      test "preserves explicit level #{inspect(level)}" do
        user = create_user()
        project = create_project(user)

        {:ok, task} =
          Tasks.insert(project, %{title: "Explicit #{unquote(level)}", level: unquote(level)})

        assert task.level == unquote(level)

        {:ok, reloaded} = Tasks.get(task.id)
        assert reloaded.level == unquote(level)
      end
    end

    for invalid_level <- ["high", "medium", "low", "story"] do
      test "rejects invalid level #{inspect(invalid_level)} on insert" do
        user = create_user()
        project = create_project(user)

        {:error, changeset} =
          Tasks.insert(project, %{title: "Bad Level", level: unquote(invalid_level)})

        assert %{level: ["is invalid"]} = errors_on(changeset)
      end
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

    test "get_by/1 returns task by short_id" do
      user = create_user()
      project = create_project(user)
      {:ok, task} = Tasks.insert(project, %{title: "Test"})

      assert {:ok, %Task{short_id: sid}} = Tasks.get_by(conditions: [short_id: task.short_id])
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

    for valid_level <- ["epic", "ticket", "task"] do
      test "accepts valid level #{inspect(valid_level)} on update" do
        user = create_user()
        project = create_project(user)
        {:ok, task} = Tasks.insert(project, %{title: "Level Update"})

        {:ok, updated} = Tasks.update(task, %{level: unquote(valid_level)})
        assert updated.level == unquote(valid_level)
      end
    end

    for invalid_level <- ["high", "medium", "low", "story"] do
      test "rejects invalid level #{inspect(invalid_level)} on update" do
        user = create_user()
        project = create_project(user)
        {:ok, task} = Tasks.insert(project, %{title: "Bad Update"})

        {:error, changeset} = Tasks.update(task, %{level: unquote(invalid_level)})
        assert %{level: ["is invalid"]} = errors_on(changeset)
      end
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

  describe "all/1" do
    test "returns tasks for project" do
      user = create_user()
      project = create_project(user)
      {:ok, _} = Tasks.insert(project, %{title: "Task 1"})
      {:ok, _} = Tasks.insert(project, %{title: "Task 2"})

      tasks = Tasks.all(conditions: [project_id: project.id], order_by: [asc: :inserted_at])
      assert length(tasks) == 2
    end
  end

  describe "find_by_uuid_prefix/3" do
    test "finds task by the first 8 characters of its UUID" do
      user = create_user()
      project = create_project(user)
      {:ok, task} = Tasks.insert(project, %{title: "Prefix Task"})

      prefix = String.slice(task.id, 0, 8)
      assert {:ok, found} = Tasks.find_by_uuid_prefix(prefix, project.id, user.id)
      assert found.id == task.id
    end

    test "finds task by shorter prefixes" do
      user = create_user()
      project = create_project(user)
      {:ok, task} = Tasks.insert(project, %{title: "Short Prefix"})

      prefix = String.slice(task.id, 0, 4)
      assert {:ok, found} = Tasks.find_by_uuid_prefix(prefix, project.id, user.id)
      assert found.id == task.id
    end

    test "is case-insensitive" do
      user = create_user()
      project = create_project(user)
      {:ok, task} = Tasks.insert(project, %{title: "Case Task"})

      prefix = task.id |> String.slice(0, 8) |> String.upcase()
      assert {:ok, found} = Tasks.find_by_uuid_prefix(prefix, project.id, user.id)
      assert found.id == task.id
    end

    test "returns :not_found for non-matching prefix" do
      user = create_user()
      project = create_project(user)
      {:ok, _task} = Tasks.insert(project, %{title: "Task"})

      assert {:error, :not_found} = Tasks.find_by_uuid_prefix("00000000", project.id, user.id)
    end

    test "scopes to project" do
      user = create_user()
      p1 = create_project(user)
      {:ok, p2} = Projects.insert(user, %{name: "Other Project"})
      {:ok, task} = Tasks.insert(p1, %{title: "P1 Task"})

      prefix = String.slice(task.id, 0, 8)

      assert {:ok, _} = Tasks.find_by_uuid_prefix(prefix, p1.id, user.id)
      assert {:error, :not_found} = Tasks.find_by_uuid_prefix(prefix, p2.id, user.id)
    end

    test "scopes to user" do
      user1 = create_user()

      user2 =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      project = create_project(user1)
      {:ok, task} = Tasks.insert(project, %{title: "User1 Task"})

      prefix = String.slice(task.id, 0, 8)

      assert {:ok, _} = Tasks.find_by_uuid_prefix(prefix, project.id, user1.id)
      assert {:error, :not_found} = Tasks.find_by_uuid_prefix(prefix, project.id, user2.id)
    end

    test "returns :invalid_prefix for non-hex input" do
      user = create_user()
      project = create_project(user)

      assert {:error, :invalid_prefix} =
               Tasks.find_by_uuid_prefix("ghijklmn", project.id, user.id)
    end

    test "returns :invalid_prefix for prefix longer than 8 characters" do
      user = create_user()
      project = create_project(user)

      assert {:error, :invalid_prefix} =
               Tasks.find_by_uuid_prefix("abcdef012", project.id, user.id)
    end

    test "returns :invalid_prefix for empty string" do
      user = create_user()
      project = create_project(user)

      assert {:error, :invalid_prefix} = Tasks.find_by_uuid_prefix("", project.id, user.id)
    end

    test "preloads sections and parent" do
      user = create_user()
      project = create_project(user)
      {:ok, task} = Tasks.insert(project, %{title: "Preload Task"})

      prefix = String.slice(task.id, 0, 8)
      {:ok, found} = Tasks.find_by_uuid_prefix(prefix, project.id, user.id)

      assert Ecto.assoc_loaded?(found.sections)
      assert Ecto.assoc_loaded?(found.parent)
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

      tasks = Tasks.list_tasks(conditions: [project_id: p1.id])
      assert length(tasks) == 1
      assert hd(tasks).title == "P1 Task"
    end

    test "filters by level" do
      user = create_user()
      project = create_project(user)
      {:ok, _} = Tasks.insert(project, %{title: "Ticket", level: "ticket"})
      {:ok, _} = Tasks.insert(project, %{title: "Task", level: "task"})

      tasks = Tasks.list_tasks(conditions: [project_id: project.id, level: "ticket"])
      assert length(tasks) == 1
      assert hd(tasks).title == "Ticket"
    end

    test "filters by priority" do
      user = create_user()
      project = create_project(user)
      {:ok, _} = Tasks.insert(project, %{title: "High Priority", priority: "high"})
      {:ok, _} = Tasks.insert(project, %{title: "Low Priority", priority: "low"})

      tasks = Tasks.list_tasks(conditions: [project_id: project.id, priority: "high"])
      assert length(tasks) == 1
      assert hd(tasks).title == "High Priority"
    end

    test "returns all tasks with no filters" do
      user = create_user()
      project = create_project(user)
      {:ok, _} = Tasks.insert(project, %{title: "Task 1"})
      {:ok, _} = Tasks.insert(project, %{title: "Task 2"})

      tasks = Tasks.list_tasks(conditions: [project_id: project.id])
      assert length(tasks) == 2
    end

    test "filters by UUID prefix" do
      user = create_user()
      project = create_project(user)
      {:ok, matching_task} = Tasks.insert(project, %{title: "Matching Task"})
      {:ok, unrelated_task} = Tasks.insert(project, %{title: "Unrelated Task"})

      prefix = String.slice(matching_task.id, 0, 12)
      tasks = Tasks.list_tasks(conditions: [project_id: project.id, search: prefix])

      assert Enum.map(tasks, & &1.id) == [matching_task.id]
      refute Enum.any?(tasks, &(&1.id == unrelated_task.id))
    end

    test "filters by step_id" do
      user = create_user()
      project = create_project(user)

      {:ok, wf} = Workflows.insert(project, %{name: "Test Workflow"})
      {:ok, step1} = WorkflowSteps.insert(wf, %{name: "step1", step_order: 1})
      {:ok, step2} = WorkflowSteps.insert(wf, %{name: "step2", step_order: 2})

      {:ok, wf} = Workflows.update(wf, %{initial_step_id: step1.id})

      {:ok, _} =
        StepTransitions.insert(wf.user_id, %{
          project_id: wf.project_id,
          from_step_id: step1.id,
          to_step_id: step2.id
        })

      {:ok, task1} = Tasks.insert(project, %{title: "Task on Step 1"})
      {:ok, task2} = Tasks.insert(project, %{title: "Task on Step 2"})
      {:ok, _task3} = Tasks.insert(project, %{title: "Task with no step"})

      {:ok, task1} = TaskWorkflows.assign_workflow(task1, wf)
      {:ok, task2_assigned} = TaskWorkflows.assign_workflow(task2, wf)
      {:ok, _} = TaskWorkflows.move_to_step(task2_assigned, step2.id)

      tasks = Tasks.list_tasks(conditions: [project_id: project.id, step_id: step1.id])
      assert length(tasks) == 1
      assert hd(tasks).id == task1.id
      assert hd(tasks).current_step_id == step1.id
    end

    test "list_tasks with no step_id condition returns tasks regardless of current_step_id" do
      user = create_user()
      project = create_project(user)

      {:ok, wf} = Workflows.insert(project, %{name: "Test Workflow"})
      {:ok, step} = WorkflowSteps.insert(wf, %{name: "test_step", step_order: 1})

      {:ok, task1} = Tasks.insert(project, %{title: "Task 1"})
      {:ok, task2} = Tasks.insert(project, %{title: "Task 2"})

      TaskWorkflows.assign_workflow(task1, wf)
      TaskWorkflows.move_to_step(task1, step.id)

      tasks = Tasks.list_tasks(conditions: [project_id: project.id])
      assert length(tasks) == 2
      task_ids = Enum.map(tasks, & &1.id)
      assert task1.id in task_ids
      assert task2.id in task_ids
    end
  end
end
