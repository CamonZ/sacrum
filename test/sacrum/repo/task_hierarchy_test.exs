defmodule Sacrum.Repo.TaskHierarchyTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.Tasks, as: AccountTasks
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Tasks
  alias Sacrum.Repo.TaskHierarchy

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

  defp assign_parent(child, parent) do
    AccountTasks.update(child, %{parent_id: parent.id})
  end

  describe "get_children/1" do
    test "returns direct children only" do
      project = setup_project()
      parent = create_task(project, "Parent")
      child1 = create_task(project, "Child1")
      child2 = create_task(project, "Child2")
      grandchild = create_task(project, "Grandchild")

      {:ok, _} = assign_parent(child1, parent)
      {:ok, _} = assign_parent(child2, parent)
      {:ok, _} = assign_parent(grandchild, child1)

      children = TaskHierarchy.get_children(parent)
      assert length(children) == 2
      titles = Enum.map(children, & &1.title)
      assert "Child1" in titles
      assert "Child2" in titles
    end
  end

  describe "get_descendants/1" do
    test "returns full subtree" do
      project = setup_project()
      root = create_task(project, "Root")
      child = create_task(project, "Child")
      grandchild = create_task(project, "Grandchild")

      {:ok, _} = assign_parent(child, root)
      {:ok, _} = assign_parent(grandchild, child)

      descendants = TaskHierarchy.get_descendants(root)
      assert length(descendants) == 2
      titles = Enum.map(descendants, & &1.title)
      assert "Child" in titles
      assert "Grandchild" in titles
    end
  end
end
