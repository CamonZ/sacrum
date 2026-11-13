defmodule Sacrum.Repo.TaskIdentifiersTest do
  use Sacrum.DataCase, async: true

  import Ecto.Query

  alias Sacrum.Accounts
  alias Sacrum.Repo
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Schemas.Project
  alias Sacrum.Repo.Schemas.Task
  alias Sacrum.Repo.Schemas.Workflow
  alias Sacrum.Repo.Users

  defp create_user(name \\ "keys") do
    {:ok, user} =
      Users.insert(%{email: "#{name}@example.com", username: name, password: "password123"})

    user
  end

  defp create_project(user, attrs) do
    {:ok, project} = Projects.insert(user, Map.merge(%{key_prefix: "KEY"}, attrs))
    project
  end

  defp create_task(user, project, attrs \\ %{}) do
    {:ok, task} = Accounts.Tasks.insert(user.id, project.id, Map.merge(%{title: "Task"}, attrs))
    task
  end

  defp reload_project(project), do: Repo.get!(Project, project.id)

  defp number(task), do: Repo.get!(Task, task.id).number

  defp set_inserted_at(task, timestamp) do
    Repo.update_all(from(t in Task, where: t.id == ^task.id), set: [inserted_at: timestamp])
  end

  describe "project key prefix" do
    test "is unset by default and tasks stay unnumbered until it is set" do
      user = create_user()
      project = create_project(user, %{name: "Vertebrae", key_prefix: nil})

      assert project.key_prefix == nil
      assert create_task(user, project).number == nil
      assert reload_project(project).last_task_number == 0
    end

    test "setting it numbers existing tasks by inserted_at then id, then continues" do
      user = create_user()
      project = create_project(user, %{name: "Vertebrae", key_prefix: nil})

      [late, tie_a, tie_b, early] =
        for title <- ["late", "tie a", "tie b", "early"] do
          create_task(user, project, %{title: title})
        end

      set_inserted_at(early, ~U[2026-01-01 00:00:00.000000Z])
      set_inserted_at(tie_a, ~U[2026-01-02 00:00:00.000000Z])
      set_inserted_at(tie_b, ~U[2026-01-02 00:00:00.000000Z])
      set_inserted_at(late, ~U[2026-01-03 00:00:00.000000Z])
      [first_tie, second_tie] = Enum.sort([tie_a.id, tie_b.id])

      assert {:ok, project} = Accounts.Projects.update(project, %{key_prefix: "vtb"})
      assert %{key_prefix: "VTB", last_task_number: 4} = project

      assert number(early) == 1
      assert Repo.get!(Task, first_tie).number == 2
      assert Repo.get!(Task, second_tie).number == 3
      assert number(late) == 4
      assert create_task(user, project).number == 5
    end

    test "enabling one project does not number another project's tasks" do
      user = create_user()
      other_user = create_user("other")
      project = create_project(user, %{name: "Vertebrae", key_prefix: nil})
      sibling = create_project(user, %{name: "Sibling", key_prefix: nil})
      foreign = create_project(other_user, %{name: "Vertebrae", key_prefix: nil})
      create_task(user, project)
      sibling_task = create_task(user, sibling)
      foreign_task = create_task(other_user, foreign)

      assert {:ok, _project} = Accounts.Projects.update(project, %{key_prefix: "VTB"})

      assert number(sibling_task) == nil
      assert number(foreign_task) == nil
    end

    test "an enabled project with no tasks starts at 1" do
      user = create_user()
      project = create_project(user, %{name: "Vertebrae", key_prefix: nil})

      assert {:ok, project} = Accounts.Projects.update(project, %{key_prefix: "VTB"})
      assert project.last_task_number == 0
      assert create_task(user, project).number == 1
    end

    test "accepts an explicit prefix, normalized to uppercase" do
      user = create_user()

      assert create_project(user, %{name: "Vertebrae", key_prefix: "vtb"}).key_prefix == "VTB"
    end

    test "rejects invalid prefixes" do
      user = create_user()

      for prefix <- ["1AB", "A-B", "ABCDEFGHIJK"] do
        assert {:error, changeset} = Projects.insert(user, %{name: "Bad", key_prefix: prefix})
        assert %{key_prefix: [_message]} = errors_on(changeset)
      end
    end

    test "can change until a task number is issued, then is immutable" do
      user = create_user()
      project = create_project(user, %{name: "Vertebrae", key_prefix: "VRT"})

      assert {:ok, project} = Accounts.Projects.update(project, %{key_prefix: nil})
      assert project.key_prefix == nil
      assert {:ok, project} = Accounts.Projects.update(project, %{key_prefix: "VTB"})
      assert project.key_prefix == "VTB"

      create_task(user, project)
      project = reload_project(project)

      assert {:error, changeset} = Accounts.Projects.update(project, %{key_prefix: "VRT"})

      assert %{key_prefix: ["cannot be changed after task identifiers have been issued"]} =
               errors_on(changeset)

      assert {:error, changeset} = Accounts.Projects.update(project, %{key_prefix: nil})
      assert %{key_prefix: [_message]} = errors_on(changeset)

      assert {:ok, renamed} = Accounts.Projects.update(project, %{name: "Renamed"})
      assert renamed.key_prefix == "VTB"
    end

    test "the database rejects prefix changes after issuance even from stale structs" do
      user = create_user()
      project = create_project(user, %{name: "Vertebrae", key_prefix: "VTB"})
      create_task(user, project)

      assert {:error, changeset} = Accounts.Projects.update(project, %{key_prefix: "VRT"})

      assert %{key_prefix: ["cannot be changed after task identifiers have been issued"]} =
               errors_on(changeset)

      assert reload_project(project).key_prefix == "VTB"
    end

    test "stays immutable after every numbered task is deleted" do
      user = create_user()
      project = create_project(user, %{name: "Vertebrae", key_prefix: "VTB"})
      task = create_task(user, project)
      assert {:ok, _deleted} = Accounts.Tasks.delete(task)

      assert {:error, changeset} =
               project |> reload_project() |> Accounts.Projects.update(%{key_prefix: "VRT"})

      assert %{key_prefix: [_message]} = errors_on(changeset)
    end
  end

  describe "task number allocation" do
    test "uses one increasing sequence across all task levels" do
      user = create_user()
      project = create_project(user, %{name: "Vertebrae", key_prefix: "VTB"})

      epic = create_task(user, project, %{level: "epic"})
      ticket = create_task(user, project, %{level: "ticket", parent_id: epic.id})
      task = create_task(user, project, %{level: "task", parent_id: ticket.id})

      assert [epic.number, ticket.number, task.number] == [1, 2, 3]
      assert reload_project(project).last_task_number == 3
    end

    test "projects and users allocate independently" do
      user = create_user()
      other_user = create_user("other")
      first = create_project(user, %{name: "First"})
      second = create_project(user, %{name: "Second"})
      foreign = create_project(other_user, %{name: "First"})

      assert create_task(user, first).number == 1
      assert create_task(user, first).number == 2
      assert create_task(user, second).number == 1
      assert create_task(other_user, foreign).number == 1
    end

    test "ignores client-supplied numbers and preserves the number on edits" do
      user = create_user()
      project = create_project(user, %{name: "Vertebrae"})
      task = create_task(user, project, %{number: 42})
      assert task.number == 1

      assert {:ok, updated} =
               Accounts.Tasks.update(task, %{title: "Renamed", level: "epic", priority: "high"})

      assert updated.number == 1

      Repo.update_all(from(t in Task, where: t.id == ^task.id), set: [number: 99])
      assert Repo.get!(Task, task.id).number == 1
    end

    test "never reuses numbers after deletion" do
      user = create_user()
      project = create_project(user, %{name: "Vertebrae"})
      first = create_task(user, project)
      second = create_task(user, project)

      assert {:ok, _deleted} = Accounts.Tasks.delete(second)
      assert {:ok, _deleted} = Accounts.Tasks.delete(first)

      assert create_task(user, project).number == 3
    end

    test "the database rejects duplicate numbers in one user/project" do
      user = create_user()
      project = create_project(user, %{name: "Vertebrae"})
      create_task(user, project)
      second = create_task(user, project)

      Repo.query!("ALTER TABLE tasks DISABLE TRIGGER tasks_assign_number")

      assert_raise Postgrex.Error, ~r/tasks_user_id_project_id_number_index/, fn ->
        Repo.update_all(from(t in Task, where: t.id == ^second.id), set: [number: 1])
      end
    end

    test "moving a task to another project assigns a destination number" do
      user = create_user()
      source = create_project(user, %{name: "Source", key_prefix: "SRC"})
      destination = create_project(user, %{name: "Destination", key_prefix: "DST"})
      create_task(user, destination)
      task = create_task(user, source)
      assert task.number == 1

      workflow =
        Repo.one!(
          from(w in Workflow, where: w.project_id == ^destination.id and w.is_default == true)
        )

      {1, [moved]} =
        Repo.update_all(
          from(t in Task, where: t.id == ^task.id, select: t),
          set: [
            project_id: destination.id,
            workflow_id: workflow.id,
            current_step_id: workflow.initial_step_id
          ]
        )

      assert moved.number == 2
      assert reload_project(source).last_task_number == 1
      assert reload_project(destination).last_task_number == 2
    end

    test "moving a task into a project without a prefix clears its number" do
      user = create_user()
      source = create_project(user, %{name: "Source"})
      destination = create_project(user, %{name: "Destination", key_prefix: nil})
      task = create_task(user, source)
      assert task.number == 1

      workflow =
        Repo.one!(
          from(w in Workflow, where: w.project_id == ^destination.id and w.is_default == true)
        )

      {1, [moved]} =
        Repo.update_all(
          from(t in Task, where: t.id == ^task.id, select: t),
          set: [
            project_id: destination.id,
            workflow_id: workflow.id,
            current_step_id: workflow.initial_step_id
          ]
        )

      assert moved.number == nil
    end

    test "rejects tasks in projects owned by another user" do
      user = create_user()
      other_user = create_user("other")
      project = create_project(user, %{name: "Vertebrae"})

      changeset =
        Task.create_changeset(%Task{project_id: project.id, user_id: other_user.id}, %{
          title: "Intruder"
        })

      assert {:error, changeset} = Repo.insert(changeset)
      assert %{project_id: [_message]} = errors_on(changeset)
      assert reload_project(project).last_task_number == 0
    end
  end

  describe "find_by_key/3" do
    test "resolves a key case-insensitively within the project" do
      user = create_user()
      project = create_project(user, %{name: "Vertebrae", key_prefix: "VTB"})
      task = create_task(user, project)

      assert {:ok, found} = Accounts.Tasks.find_by_key(user.id, project.id, "VTB-1")
      assert found.id == task.id
      assert {:ok, %Task{id: id}} = Accounts.Tasks.find_by_key(user.id, project.id, " vtb-1 ")
      assert id == task.id
    end

    test "does not cross project or ownership boundaries" do
      user = create_user()
      other_user = create_user("other")
      project = create_project(user, %{name: "Vertebrae", key_prefix: "VTB"})
      sibling = create_project(user, %{name: "Sibling", key_prefix: "VTB"})
      create_task(user, project)

      assert {:error, :not_found} = Accounts.Tasks.find_by_key(user.id, sibling.id, "VTB-1")
      assert {:error, :not_found} = Accounts.Tasks.find_by_key(other_user.id, project.id, "VTB-1")
      assert {:error, :not_found} = Accounts.Tasks.find_by_key(user.id, project.id, "ABC-1")
      assert {:error, :not_found} = Accounts.Tasks.find_by_key(user.id, project.id, "VTB-2")
    end

    test "rejects malformed keys" do
      user = create_user()
      project = create_project(user, %{name: "Vertebrae", key_prefix: "VTB"})

      for key <- ["VTB", "VTB-", "VTB-0", "VTB-1x", "1-1", "VTB-1234567890"] do
        assert {:error, :invalid_key} = Accounts.Tasks.find_by_key(user.id, project.id, key)
      end
    end
  end
end
