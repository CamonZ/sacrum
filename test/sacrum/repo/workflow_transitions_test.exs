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

  describe "sync_transitions/2" do
    test "adds new transitions" do
      {_project, w1, w2} = create_workflows()

      {:ok, transitions} =
        Workflows.sync_transitions(w1, [
          %{"to_workflow_id" => w2.id, "label" => "promote"}
        ])

      assert length(transitions) == 1
      assert hd(transitions).to_workflow_id == w2.id
      assert hd(transitions).label == "promote"
    end

    test "removes transitions not in the incoming list" do
      {_project, w1, w2} = create_workflows()

      {:ok, _} =
        WorkflowTransitions.insert(%{
          from_workflow_id: w1.id,
          to_workflow_id: w2.id,
          label: "old"
        })

      {:ok, transitions} = Workflows.sync_transitions(w1, [])

      assert transitions == []
    end

    test "updates changed transitions" do
      {_project, w1, w2} = create_workflows()

      {:ok, _} =
        WorkflowTransitions.insert(%{
          from_workflow_id: w1.id,
          to_workflow_id: w2.id,
          label: "old_label"
        })

      {:ok, transitions} =
        Workflows.sync_transitions(w1, [
          %{"to_workflow_id" => w2.id, "label" => "new_label"}
        ])

      assert length(transitions) == 1
      assert hd(transitions).label == "new_label"
    end

    test "handles mixed add/remove/update in one call" do
      {:ok, user} =
        Users.insert(%{email: "mix@example.com", username: "mixuser", password: "password123"})

      {:ok, project} = Projects.insert(user, %{name: "Mix Project"})
      {:ok, w1} = Workflows.insert(project, %{name: "Source"})
      {:ok, w2} = Workflows.insert(project, %{name: "Target A"})
      {:ok, w3} = Workflows.insert(project, %{name: "Target B"})
      {:ok, w4} = Workflows.insert(project, %{name: "Target C"})

      # Start with transitions to w2 and w3
      {:ok, _} =
        WorkflowTransitions.insert(%{from_workflow_id: w1.id, to_workflow_id: w2.id, label: "a"})

      {:ok, _} =
        WorkflowTransitions.insert(%{from_workflow_id: w1.id, to_workflow_id: w3.id, label: "b"})

      # Sync: keep w3 (updated label), remove w2, add w4
      {:ok, transitions} =
        Workflows.sync_transitions(w1, [
          %{"to_workflow_id" => w3.id, "label" => "updated_b"},
          %{"to_workflow_id" => w4.id, "label" => "c"}
        ])

      target_ids = Enum.map(transitions, & &1.to_workflow_id) |> Enum.sort()
      assert target_ids == Enum.sort([w3.id, w4.id])

      updated = Enum.find(transitions, &(&1.to_workflow_id == w3.id))
      assert updated.label == "updated_b"
    end

    test "returns error for duplicate to_workflow_id in transitions" do
      {_project, w1, w2} = create_workflows()

      {:error, _changeset} =
        Workflows.sync_transitions(w1, [
          %{"to_workflow_id" => w2.id, "label" => "first"},
          %{"to_workflow_id" => w2.id, "label" => "second"}
        ])
    end
  end
end
