defmodule Sacrum.Repo.WorkflowTransitionsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.WorkflowTransitions
  alias Sacrum.Repo.Workflows
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Schemas.WorkflowTransition

  @valid_user_attrs %{
    email: "test@example.com",
    username: "testuser",
    password: "password123"
  }

  defp create_workflows do
    {:ok, user} = Users.insert(@valid_user_attrs)
    {:ok, project} = Projects.insert(user, %{name: "My Project"})
    {:ok, w1} = Workflows.insert(project, %{name: "Implementation"})
    {:ok, w2} = Workflows.insert(project, %{name: "Review"})
    {project, w1, w2}
  end

  describe "insert/1" do
    test "creates workflow-to-workflow transition" do
      {_project, w1, w2} = create_workflows()

      assert {:ok, %WorkflowTransition{} = transition} =
               WorkflowTransitions.insert(%{
                 from_workflow_id: w1.id,
                 to_workflow_id: w2.id,
                 label: "promote"
               })

      assert transition.from_workflow_id == w1.id
      assert transition.to_workflow_id == w2.id
      assert transition.label == "promote"
    end

    test "rejects duplicate from/to pair" do
      {_project, w1, w2} = create_workflows()

      {:ok, _} =
        WorkflowTransitions.insert(%{from_workflow_id: w1.id, to_workflow_id: w2.id})

      assert {:error, changeset} =
               WorkflowTransitions.insert(%{from_workflow_id: w1.id, to_workflow_id: w2.id})

      assert %{from_workflow_id: ["transition already exists between these workflows"]} =
               errors_on(changeset)
    end
  end

  describe "list_for_workflow/1" do
    test "returns transitions from a workflow" do
      {_project, w1, w2} = create_workflows()
      {:ok, _} = WorkflowTransitions.insert(%{from_workflow_id: w1.id, to_workflow_id: w2.id})

      transitions = WorkflowTransitions.list_for_workflow(w1)
      assert length(transitions) == 1
      assert hd(transitions).to_workflow_id == w2.id
    end
  end

  describe "delete/1" do
    test "removes the transition" do
      {_project, w1, w2} = create_workflows()

      {:ok, transition} =
        WorkflowTransitions.insert(%{from_workflow_id: w1.id, to_workflow_id: w2.id})

      assert {:ok, _} = WorkflowTransitions.delete(transition)
      assert {:error, :not_found} = WorkflowTransitions.get(transition.id)
    end
  end
end
