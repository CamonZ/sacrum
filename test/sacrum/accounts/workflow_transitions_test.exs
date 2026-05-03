defmodule Sacrum.Accounts.WorkflowTransitionsTest do
  use Sacrum.DataCase, async: false

  alias Sacrum.Accounts.WorkflowTransitions
  alias Sacrum.Accounts.Workflows
  alias Sacrum.Accounts.Projects
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Schemas.WorkflowTransition

  @valid_user_attrs %{
    email: "test@example.com",
    username: "testuser",
    password: "password123"
  }

  defp create_user(attrs \\ @valid_user_attrs) do
    {:ok, user} = Users.insert(attrs)
    user
  end

  defp create_workflows(user) do
    {:ok, project} = Projects.insert(user.id, %{name: "Test Project"})
    {:ok, workflow1} = Workflows.insert(user.id, project.id, %{name: "Implementation"})
    {:ok, workflow2} = Workflows.insert(user.id, project.id, %{name: "Review"})
    {project, workflow1, workflow2}
  end

  describe "insert/2" do
    test "creates workflow transition scoped to user_id, project_id, and workflow ids" do
      user = create_user()
      {project, workflow1, workflow2} = create_workflows(user)

      assert {:ok, %WorkflowTransition{} = transition} =
               WorkflowTransitions.insert(user.id, %{
                 "from_workflow_id" => workflow1.id,
                 "to_workflow_id" => workflow2.id,
                 "project_id" => project.id,
                 "label" => "promote"
               })

      assert transition.user_id == user.id
      assert transition.project_id == project.id
      assert transition.from_workflow_id == workflow1.id
      assert transition.to_workflow_id == workflow2.id
      assert transition.label == "promote"
    end
  end

  describe "get_by/2" do
    test "returns transition only if scoped to user" do
      user1 = create_user()
      {project1, workflow1a, workflow1b} = create_workflows(user1)

      user2 =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      {project2, workflow2a, workflow2b} = create_workflows(user2)

      {:ok, transition} =
        WorkflowTransitions.insert(user1.id, %{
          "from_workflow_id" => workflow1a.id,
          "to_workflow_id" => workflow1b.id,
          "project_id" => project1.id
        })

      {:ok, _} =
        WorkflowTransitions.insert(user2.id, %{
          "from_workflow_id" => workflow2a.id,
          "to_workflow_id" => workflow2b.id,
          "project_id" => project2.id
        })

      # User1 can access their transition
      assert {:ok, found} = WorkflowTransitions.get_by(user1.id, conditions: [id: transition.id])
      assert found.id == transition.id
      assert found.user_id == user1.id

      # User2 cannot access user1's transition
      assert {:error, :not_found} =
               WorkflowTransitions.get_by(user2.id, conditions: [id: transition.id])
    end
  end

  describe "list_by/2" do
    test "returns only transitions scoped to user" do
      user1 = create_user()
      {project1, workflow1a, workflow1b} = create_workflows(user1)

      user2 =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      {project2, workflow2a, workflow2b} = create_workflows(user2)

      {:ok, _} =
        WorkflowTransitions.insert(user1.id, %{
          "from_workflow_id" => workflow1a.id,
          "to_workflow_id" => workflow1b.id,
          "project_id" => project1.id
        })

      {:ok, _} =
        WorkflowTransitions.insert(user2.id, %{
          "from_workflow_id" => workflow2a.id,
          "to_workflow_id" => workflow2b.id,
          "project_id" => project2.id
        })

      transitions = WorkflowTransitions.list_by(user1.id)
      assert length(transitions) == 1
      assert hd(transitions).user_id == user1.id
    end
  end

  describe "broadcasts" do
    test "insert/2 broadcasts workflow_transition_created on success" do
      user = create_user()
      {project, workflow1, workflow2} = create_workflows(user)

      :ok = Phoenix.PubSub.subscribe(Sacrum.PubSub, "project:#{project.id}")

      {:ok, transition} =
        WorkflowTransitions.insert(user.id, %{
          "from_workflow_id" => workflow1.id,
          "to_workflow_id" => workflow2.id,
          "project_id" => project.id,
          "label" => "promote"
        })

      assert_receive %Phoenix.Socket.Broadcast{
        event: "workflow_transition_created",
        payload: payload
      }

      assert payload.id == transition.id
      assert payload.from_workflow_id == workflow1.id
      assert payload.to_workflow_id == workflow2.id
      assert payload.label == "promote"
    end

    test "insert/2 does not broadcast on validation error" do
      user = create_user()
      {project, _workflow1, _workflow2} = create_workflows(user)

      :ok = Phoenix.PubSub.subscribe(Sacrum.PubSub, "project:#{project.id}")

      assert {:error, %Ecto.Changeset{}} =
               WorkflowTransitions.insert(user.id, %{"project_id" => project.id})

      refute_receive %Phoenix.Socket.Broadcast{event: "workflow_transition_created"}, 100
    end

    test "delete/1 broadcasts workflow_transition_deleted on success" do
      user = create_user()
      {project, workflow1, workflow2} = create_workflows(user)

      {:ok, transition} =
        WorkflowTransitions.insert(user.id, %{
          "from_workflow_id" => workflow1.id,
          "to_workflow_id" => workflow2.id,
          "project_id" => project.id
        })

      :ok = Phoenix.PubSub.subscribe(Sacrum.PubSub, "project:#{project.id}")

      {:ok, _deleted} = WorkflowTransitions.delete(transition)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "workflow_transition_deleted",
        payload: payload
      }

      assert payload.id == transition.id
      assert payload.from_workflow_id == workflow1.id
      assert payload.to_workflow_id == workflow2.id
    end
  end
end
