defmodule Sacrum.Repo.TaskSectionsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Tasks
  alias Sacrum.Repo.TaskSections

  @valid_user_attrs %{
    email: "test@example.com",
    username: "testuser",
    password: "password123"
  }

  defp setup_task do
    {:ok, user} = Users.insert(@valid_user_attrs)
    {:ok, project} = Projects.insert(user, %{name: "Test Project"})
    {:ok, task} = Tasks.insert(project, %{title: "Test Task"})
    task
  end

  describe "insert/2" do
    test "creates section with valid attrs" do
      task = setup_task()

      {:ok, section} =
        TaskSections.insert(task, %{section_type: "goal", content: "Do the thing"})

      assert section.section_type == "goal"
      assert section.content == "Do the thing"
      assert section.task_id == task.id
    end

    test "rejects missing section_type or content" do
      task = setup_task()

      {:error, changeset} = TaskSections.insert(task, %{})
      errors = errors_on(changeset)
      assert errors[:section_type]
      assert errors[:content]
    end
  end

  describe "all/1" do
    test "returns sections belonging to the given task" do
      task = setup_task()
      {:ok, _} = TaskSections.insert(task, %{section_type: "goal", content: "Goal 1"})
      {:ok, _} = TaskSections.insert(task, %{section_type: "checklist_item", content: "Checklist Item 1"})

      sections =
        TaskSections.all(
          conditions: [task_id: task.id],
          order_by: [asc: :section_order, asc: :inserted_at]
        )

      assert length(sections) == 2
    end
  end

  describe "update/2" do
    test "updates content and section_order" do
      task = setup_task()
      {:ok, section} = TaskSections.insert(task, %{section_type: "goal", content: "Original"})

      {:ok, updated} = TaskSections.update(section, %{content: "Updated", section_order: 5})
      assert updated.content == "Updated"
      assert updated.section_order == 5
    end
  end

  describe "delete/1" do
    test "removes the section" do
      task = setup_task()
      {:ok, section} = TaskSections.insert(task, %{section_type: "goal", content: "Temp"})

      {:ok, _} = TaskSections.delete(section)
      assert {:error, :not_found} = TaskSections.get(section.id)
    end
  end

  describe "section_type validation" do
    test "accepts valid section types" do
      task = setup_task()
      valid_types = [
        "anti_pattern",
        "checklist_item",
        "constraint",
        "context",
        "current_behavior",
        "desired_behavior",
        "failure_test",
        "goal",
        "testing_criterion"
      ]

      for section_type <- valid_types do
        {:ok, section} = TaskSections.insert(task, %{section_type: section_type, content: "Test content"})
        assert section.section_type == section_type
      end
    end

    test "rejects invalid section type" do
      task = setup_task()
      {:error, changeset} = TaskSections.insert(task, %{section_type: "invalid_type", content: "Test"})
      errors = errors_on(changeset)
      assert errors[:section_type]
    end
  end
end
