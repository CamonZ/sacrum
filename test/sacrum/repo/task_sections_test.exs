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
    {:ok, user} = Users.insert(unique_user_attrs())
    {:ok, project} = Projects.insert(user, %{name: "Test Project"})
    {:ok, task} = Tasks.insert(project, %{title: "Test Task"})
    task
  end

  defp unique_user_attrs do
    unique = System.unique_integer([:positive])

    %{
      @valid_user_attrs
      | email: "test-#{unique}@example.com",
        username: "testuser#{unique}"
    }
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

    test "honors explicit section_order unchanged" do
      task = setup_task()

      {:ok, section} =
        TaskSections.insert(task, %{
          section_type: "checklist_item",
          content: "Explicit order",
          section_order: 12
        })

      assert section.section_order == 12
    end

    test "rejects missing section_type or content" do
      task = setup_task()

      {:error, changeset} = TaskSections.insert(task, %{})
      errors = errors_on(changeset)
      assert errors[:section_type]
      assert errors[:content]
    end

    test "rejects duplicate non-null section_order for the same task and section_type" do
      task = setup_task()

      attrs = %{section_type: "checklist_item", content: "First", section_order: 1}
      {:ok, first_section} = TaskSections.insert(task, attrs)

      assert {:error, changeset} =
               TaskSections.insert(task, %{attrs | content: "Second"})

      assert %{section_order: ["has already been taken"]} = errors_on(changeset)
      assert first_section.section_order == 1
    end

    test "auto-assigns omitted and nil section_order for the same task and section_type" do
      task = setup_task()

      {:ok, first_section} =
        TaskSections.insert(task, %{
          section_type: "checklist_item",
          content: "First ordered item"
        })

      {:ok, second_section} =
        TaskSections.insert(task, %{
          section_type: "checklist_item",
          content: "Second ordered item",
          section_order: nil
        })

      assert first_section.section_order == 0
      assert second_section.section_order == 1
      assert first_section.id != second_section.id
    end

    test "create-delete-create keeps gaps and assigns max section_order plus one" do
      task = setup_task()

      {:ok, first_section} =
        TaskSections.insert(task, %{section_type: "checklist_item", content: "First"})

      {:ok, second_section} =
        TaskSections.insert(task, %{section_type: "checklist_item", content: "Second"})

      {:ok, third_section} =
        TaskSections.insert(task, %{section_type: "checklist_item", content: "Third"})

      assert Enum.map([first_section, second_section, third_section], & &1.section_order) == [
               0,
               1,
               2
             ]

      {:ok, _deleted} = TaskSections.delete(first_section)

      {:ok, fourth_section} =
        TaskSections.insert(task, %{section_type: "checklist_item", content: "Fourth"})

      assert fourth_section.section_order == 3
    end

    test "allows the same non-null section_order for different tasks" do
      first_task = setup_task()
      second_task = setup_task()

      {:ok, first_section} =
        TaskSections.insert(first_task, %{
          section_type: "goal",
          content: "First task goal",
          section_order: 1
        })

      {:ok, second_section} =
        TaskSections.insert(second_task, %{
          section_type: "goal",
          content: "Second task goal",
          section_order: 1
        })

      assert first_section.task_id == first_task.id
      assert second_section.task_id == second_task.id
      assert first_section.section_order == second_section.section_order
    end

    test "allows the same non-null section_order for different section types" do
      task = setup_task()

      {:ok, goal_section} =
        TaskSections.insert(task, %{section_type: "goal", content: "Goal", section_order: 1})

      {:ok, criterion_section} =
        TaskSections.insert(task, %{
          section_type: "testing_criterion",
          content: "Criterion",
          section_order: 1
        })

      assert goal_section.task_id == criterion_section.task_id
      assert goal_section.section_type != criterion_section.section_type
      assert goal_section.section_order == criterion_section.section_order
    end
  end

  describe "all/1" do
    test "returns sections belonging to the given task" do
      task = setup_task()
      {:ok, _} = TaskSections.insert(task, %{section_type: "goal", content: "Goal 1"})

      {:ok, _} =
        TaskSections.insert(task, %{section_type: "checklist_item", content: "Checklist Item 1"})

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
        "assumptions",
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
        {:ok, section} =
          TaskSections.insert(task, %{section_type: section_type, content: "Test content"})

        assert section.section_type == section_type
      end
    end

    test "rejects invalid section type" do
      task = setup_task()

      {:error, changeset} =
        TaskSections.insert(task, %{section_type: "invalid_type", content: "Test"})

      errors = errors_on(changeset)
      assert errors[:section_type]
    end

    test "creates assumptions section with plain text content" do
      task = setup_task()

      {:ok, section} =
        TaskSections.insert(task, %{
          section_type: "assumptions",
          content: "This is a plain text assumption for the task"
        })

      assert section.section_type == "assumptions"
      assert section.content == "This is a plain text assumption for the task"
      assert section.task_id == task.id
    end
  end

  describe "artifact link subject helpers" do
    test "builds testing_criterion artifact subjects for evidence and attachment links" do
      task = setup_task()

      {:ok, section} =
        TaskSections.insert(task, %{
          section_type: "testing_criterion",
          content: "The implementation preserves artifact provenance."
        })

      section_id = section.id

      assert %{
               subject_type: "task_section",
               subject_id: ^section_id,
               relationship_kind: "evidence_for"
             } = TaskSections.artifact_link_subject(section, :evidence_for)

      assert %{
               subject_type: "task_section",
               subject_id: ^section_id,
               relationship_kind: "attached_to"
             } = TaskSections.artifact_link_subject(section, :attached_to)
    end
  end
end
