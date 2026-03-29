defmodule Sacrum.Accounts.WorkflowsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.Workflows
  alias Sacrum.Accounts.Projects
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Schemas.Workflow

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
    {:ok, project} = Projects.insert(user.id, %{name: "Test Project"})
    project
  end

  describe "insert/3" do
    test "creates workflow scoped to user_id and project_id" do
      user = create_user()
      project = create_project(user)

      assert {:ok, %Workflow{} = workflow} =
               Workflows.insert(user.id, project.id, %{name: "My Workflow"})

      assert workflow.user_id == user.id
      assert workflow.project_id == project.id
      assert workflow.name == "My Workflow"
    end

    test "accepts project struct and extracts ids" do
      user = create_user()
      project = create_project(user)

      assert {:ok, %Workflow{} = workflow} =
               Workflows.insert(project, %{name: "My Workflow"})

      assert workflow.user_id == user.id
      assert workflow.project_id == project.id
    end
  end

  describe "get_by/2" do
    test "returns workflow only if scoped to user" do
      user1 = create_user()
      project1 = create_project(user1)

      user2 =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      project2 = create_project(user2)

      {:ok, workflow} = Workflows.insert(user1.id, project1.id, %{name: "User1 Workflow"})
      {:ok, _} = Workflows.insert(user2.id, project2.id, %{name: "User2 Workflow"})

      # User1 can access their workflow
      assert {:ok, found} = Workflows.get_by(user1.id, conditions: [id: workflow.id])
      assert found.id == workflow.id
      assert found.user_id == user1.id

      # User2 cannot access user1's workflow
      assert {:error, :not_found} = Workflows.get_by(user2.id, conditions: [id: workflow.id])
    end
  end

  describe "list_by/2" do
    test "returns only workflows scoped to user" do
      user1 = create_user()
      project1 = create_project(user1)

      user2 =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      project2 = create_project(user2)

      {:ok, _} = Workflows.insert(user1.id, project1.id, %{name: "User1 Workflow"})
      {:ok, _} = Workflows.insert(user2.id, project2.id, %{name: "User2 Workflow"})

      workflows = Workflows.list_by(user1.id)
      assert length(workflows) == 1
      assert hd(workflows).user_id == user1.id
    end

    test "filters by project_id" do
      user = create_user()
      project1 = create_project(user)
      {:ok, project2} = Projects.insert(user.id, %{name: "Project 2"})

      {:ok, _} = Workflows.insert(user.id, project1.id, %{name: "Workflow 1"})
      {:ok, _} = Workflows.insert(user.id, project2.id, %{name: "Workflow 2"})

      workflows = Workflows.list_by(user.id, conditions: [project_id: project1.id])
      assert length(workflows) == 1
      assert hd(workflows).project_id == project1.id
    end
  end

  describe "default workflow validation" do
    test "createWorkflow with is_default=true and no track returns validation error" do
      user = create_user()
      project = create_project(user)

      assert {:error, changeset} =
               Workflows.insert(user.id, project.id, %{name: "Default", is_default: true})

      assert Enum.any?(changeset.errors, fn {field, {msg, _opts}} ->
               field == :track and String.contains?(msg, "must be set")
             end)
    end

    test "createWorkflow with is_default=true and track set succeeds" do
      user = create_user()
      project = create_project(user)

      assert {:ok, %Workflow{is_default: true, track: "frontend"}} =
               Workflows.insert(user.id, project.id, %{
                 name: "Default Frontend",
                 is_default: true,
                 track: "frontend"
               })
    end

    test "Second is_default=true workflow on same track is rejected (uniqueness per track)" do
      user = create_user()
      project = create_project(user)

      # Create first default workflow for track "frontend"
      assert {:ok, _} =
               Workflows.insert(user.id, project.id, %{
                 name: "Default Frontend 1",
                 is_default: true,
                 track: "frontend"
               })

      # Try to create second default for same track
      assert {:error, changeset} =
               Workflows.insert(user.id, project.id, %{
                 name: "Default Frontend 2",
                 is_default: true,
                 track: "frontend"
               })

      # Check for uniqueness constraint error
      assert Enum.any?(changeset.errors, fn {field, {msg, _meta}} ->
               (field == :track or field == :project_id) and String.contains?(msg, "default workflow")
             end)
    end

    test "is_default=true workflows on different tracks both succeed" do
      user = create_user()
      project = create_project(user)

      assert {:ok, wf1} =
               Workflows.insert(user.id, project.id, %{
                 name: "Default Frontend",
                 is_default: true,
                 track: "frontend"
               })

      assert {:ok, wf2} =
               Workflows.insert(user.id, project.id, %{
                 name: "Default Backend",
                 is_default: true,
                 track: "backend"
               })

      assert wf1.id != wf2.id
      assert wf1.track == "frontend"
      assert wf2.track == "backend"
    end
  end
end
