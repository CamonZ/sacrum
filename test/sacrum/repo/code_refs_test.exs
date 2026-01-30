defmodule Sacrum.Repo.CodeRefsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Tasks
  alias Sacrum.Repo.TaskSections
  alias Sacrum.Repo.CodeRefs

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

  describe "insert_for_task/2" do
    test "creates code_ref linked to a task" do
      task = setup_task()

      {:ok, ref} =
        CodeRefs.insert_for_task(task, %{
          path: "lib/foo.ex",
          line_start: 10,
          line_end: 20,
          name: "my_func"
        })

      assert ref.task_id == task.id
      assert ref.path == "lib/foo.ex"
      assert ref.line_start == 10
    end
  end

  describe "insert_for_section/2" do
    test "creates code_ref linked to a section" do
      task = setup_task()
      {:ok, section} = TaskSections.insert(task, %{section_type: "goal", content: "Content"})

      {:ok, ref} = CodeRefs.insert_for_section(section.id, task.user_id, %{path: "lib/bar.ex"})
      assert ref.section_id == section.id
      assert ref.path == "lib/bar.ex"
    end
  end

  describe "validation" do
    test "rejects code_ref with neither task_id nor section_id" do
      result =
        %Sacrum.Repo.Schemas.CodeRef{}
        |> Sacrum.Repo.Schemas.CodeRef.changeset(%{path: "lib/foo.ex"})

      assert %{task_id: _} = errors_on(result)
    end
  end

  describe "list_for_task/1" do
    test "returns refs belonging to the given task" do
      task = setup_task()
      {:ok, _} = CodeRefs.insert_for_task(task, %{path: "lib/a.ex"})
      {:ok, _} = CodeRefs.insert_for_task(task, %{path: "lib/b.ex"})

      refs = CodeRefs.list_for_task(task)
      assert length(refs) == 2
    end
  end

  describe "delete/1" do
    test "removes the code ref" do
      task = setup_task()
      {:ok, ref} = CodeRefs.insert_for_task(task, %{path: "lib/temp.ex"})

      {:ok, _} = CodeRefs.delete(ref)
      assert {:error, :not_found} = CodeRefs.get(ref.id)
    end
  end
end
