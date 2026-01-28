defmodule Sacrum.Repo.TaskHierarchyTest do
  use Sacrum.DataCase, async: true

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

  describe "set_parent/2" do
    test "creates parent-child relationship" do
      project = setup_project()
      parent = create_task(project, "Parent")
      child = create_task(project, "Child")

      assert {:ok, _} = TaskHierarchy.set_parent(child, parent)
    end

    test "rejects setting a second parent" do
      project = setup_project()
      parent1 = create_task(project, "Parent1")
      parent2 = create_task(project, "Parent2")
      child = create_task(project, "Child")

      {:ok, _} = TaskHierarchy.set_parent(child, parent1)
      {:error, changeset} = TaskHierarchy.set_parent(child, parent2)
      assert %{child_id: ["task already has a parent"]} = errors_on(changeset)
    end
  end

  describe "get_children/1" do
    test "returns direct children only" do
      project = setup_project()
      parent = create_task(project, "Parent")
      child1 = create_task(project, "Child1")
      child2 = create_task(project, "Child2")
      grandchild = create_task(project, "Grandchild")

      {:ok, _} = TaskHierarchy.set_parent(child1, parent)
      {:ok, _} = TaskHierarchy.set_parent(child2, parent)
      {:ok, _} = TaskHierarchy.set_parent(grandchild, child1)

      children = TaskHierarchy.get_children(parent)
      assert length(children) == 2
      titles = Enum.map(children, & &1.title)
      assert "Child1" in titles
      assert "Child2" in titles
    end
  end

  describe "get_ancestors/1" do
    test "returns ancestor chain in order" do
      project = setup_project()
      root = create_task(project, "Root")
      mid = create_task(project, "Mid")
      leaf = create_task(project, "Leaf")

      {:ok, _} = TaskHierarchy.set_parent(mid, root)
      {:ok, _} = TaskHierarchy.set_parent(leaf, mid)

      ancestors = TaskHierarchy.get_ancestors(leaf)
      assert length(ancestors) == 2
      assert [%{title: "Mid"}, %{title: "Root"}] = ancestors
    end
  end

  describe "get_descendants/1" do
    test "returns full subtree" do
      project = setup_project()
      root = create_task(project, "Root")
      child = create_task(project, "Child")
      grandchild = create_task(project, "Grandchild")

      {:ok, _} = TaskHierarchy.set_parent(child, root)
      {:ok, _} = TaskHierarchy.set_parent(grandchild, child)

      descendants = TaskHierarchy.get_descendants(root)
      assert length(descendants) == 2
      titles = Enum.map(descendants, & &1.title)
      assert "Child" in titles
      assert "Grandchild" in titles
    end
  end

  describe "remove_parent/1" do
    test "removes the hierarchy link" do
      project = setup_project()
      parent = create_task(project, "Parent")
      child = create_task(project, "Child")

      {:ok, _} = TaskHierarchy.set_parent(child, parent)
      {:ok, _} = TaskHierarchy.remove_parent(child)

      assert TaskHierarchy.get_children(parent) == []
    end
  end
end
