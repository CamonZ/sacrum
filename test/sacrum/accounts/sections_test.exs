defmodule Sacrum.Accounts.SectionsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.Sections
  alias Sacrum.Accounts.Tasks
  alias Sacrum.Accounts.Projects
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Schemas.TaskSection

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

  describe "insert/2" do
    test "creates section scoped to user_id, project_id, and task_id" do
      user = create_user()
      {project, task} = create_task(user)

      assert {:ok, %TaskSection{} = section} =
               Sections.insert(user.id, %{
                 "task_id" => task.id,
                 "project_id" => project.id,
                 "section_type" => "context",
                 "content" => "Some content"
               })

      assert section.user_id == user.id
      assert section.project_id == project.id
      assert section.task_id == task.id
      assert section.section_type == "context"
      assert section.content == "Some content"
    end
  end

  describe "get_by/2" do
    test "returns section only if scoped to user" do
      user1 = create_user()
      {project1, task1} = create_task(user1)

      user2 =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      {project2, task2} = create_task(user2)

      {:ok, section} =
        Sections.insert(user1.id, %{
          "task_id" => task1.id,
          "project_id" => project1.id,
          "section_type" => "context",
          "content" => "User1 content"
        })

      {:ok, _} =
        Sections.insert(user2.id, %{
          "task_id" => task2.id,
          "project_id" => project2.id,
          "section_type" => "context",
          "content" => "User2 content"
        })

      # User1 can access their section
      assert {:ok, found} = Sections.get_by(user1.id, conditions: [id: section.id])
      assert found.id == section.id

      # User2 cannot access user1's section
      assert {:error, :not_found} = Sections.get_by(user2.id, conditions: [id: section.id])
    end
  end
end
