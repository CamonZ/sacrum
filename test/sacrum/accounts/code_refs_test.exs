defmodule Sacrum.Accounts.CodeRefsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.CodeRefs
  alias Sacrum.Accounts.Sections
  alias Sacrum.Accounts.Tasks
  alias Sacrum.Accounts.Projects
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Schemas.CodeRef

  @valid_user_attrs %{
    email: "test@example.com",
    username: "testuser",
    password: "password123"
  }

  defp create_user(attrs \\ @valid_user_attrs) do
    {:ok, user} = Users.insert(attrs)
    user
  end

  defp create_task(user) do
    {:ok, project} = Projects.insert(user.id, %{name: "Test Project"})
    {:ok, task} = Tasks.insert(user.id, project.id, %{title: "Test Task"})
    {project, task}
  end

  describe "insert_for_task/2" do
    test "creates code ref scoped to user_id, project_id, and task_id" do
      user = create_user()
      {project, task} = create_task(user)

      assert {:ok, %CodeRef{} = ref} =
               CodeRefs.insert_for_task(user.id, %{
                 "task_id" => task.id,
                 "project_id" => project.id,
                 "path" => "lib/example.ex",
                 "line_start" => 1
               })

      assert ref.user_id == user.id
      assert ref.project_id == project.id
      assert ref.task_id == task.id
      assert ref.path == "lib/example.ex"
    end
  end

  describe "insert_for_section/2" do
    test "creates code ref scoped to user_id, project_id, and section_id" do
      user = create_user()
      {project, task} = create_task(user)

      {:ok, section} =
        Sections.insert(user.id, %{
          "task_id" => task.id,
          "project_id" => project.id,
          "section_type" => "implementation",
          "content" => "Implementation details"
        })

      assert {:ok, %CodeRef{} = ref} =
               CodeRefs.insert_for_section(user.id, %{
                 "section_id" => section.id,
                 "project_id" => project.id,
                 "path" => "lib/example.ex",
                 "line_start" => 10
               })

      assert ref.user_id == user.id
      assert ref.project_id == project.id
      assert ref.section_id == section.id
      assert ref.path == "lib/example.ex"
    end
  end

  describe "get_by/2" do
    test "returns code ref only if scoped to user" do
      user1 = create_user()
      {project1, task1} = create_task(user1)

      user2 =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      {project2, task2} = create_task(user2)

      {:ok, ref} =
        CodeRefs.insert_for_task(user1.id, %{
          "task_id" => task1.id,
          "project_id" => project1.id,
          "path" => "lib/example.ex",
          "line_start" => 1
        })

      {:ok, _} =
        CodeRefs.insert_for_task(user2.id, %{
          "task_id" => task2.id,
          "project_id" => project2.id,
          "path" => "lib/other.ex",
          "line_start" => 1
        })

      # User1 can access their code ref
      assert {:ok, found} = CodeRefs.get_by(user1.id, conditions: [id: ref.id])
      assert found.id == ref.id
      assert found.user_id == user1.id

      # User2 cannot access user1's code ref
      assert {:error, :not_found} = CodeRefs.get_by(user2.id, conditions: [id: ref.id])
    end
  end

  describe "list_by/2" do
    test "returns only code refs scoped to user" do
      user1 = create_user()
      {project1, task1} = create_task(user1)

      user2 =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      {project2, task2} = create_task(user2)

      {:ok, _} =
        CodeRefs.insert_for_task(user1.id, %{
          "task_id" => task1.id,
          "project_id" => project1.id,
          "path" => "lib/example.ex",
          "line_start" => 1
        })

      {:ok, _} =
        CodeRefs.insert_for_task(user2.id, %{
          "task_id" => task2.id,
          "project_id" => project2.id,
          "path" => "lib/other.ex",
          "line_start" => 1
        })

      refs = CodeRefs.list_by(user1.id)
      assert length(refs) == 1
      assert hd(refs).user_id == user1.id
    end
  end
end
