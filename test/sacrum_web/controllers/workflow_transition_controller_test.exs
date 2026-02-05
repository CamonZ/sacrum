defmodule SacrumWeb.WorkflowTransitionControllerTest do
  use SacrumWeb.ConnCase, async: true

  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Workflows
  alias Sacrum.Repo.WorkflowSteps
  alias Sacrum.Repo.WorkflowTransitions

  defp setup_authenticated(%{conn: conn}) do
    user = create_user()
    conn = authenticate(conn, user)
    {:ok, project} = Projects.insert(user, %{name: "Test Project"})
    {:ok, workflow1} = Workflows.insert(project, %{name: "Implementation"})
    {:ok, workflow2} = Workflows.insert(project, %{name: "Review"})
    %{conn: conn, user: user, project: project, workflow1: workflow1, workflow2: workflow2}
  end

  describe "unauthenticated requests" do
    test "POST returns 401 without auth header", %{conn: conn} do
      conn = post(conn, ~p"/api/workflows/#{Ecto.UUID.generate()}/transitions")
      assert json_response(conn, 401)
    end

    test "DELETE returns 401 without auth header", %{conn: conn} do
      conn =
        delete(
          conn,
          ~p"/api/workflows/#{Ecto.UUID.generate()}/transitions/#{Ecto.UUID.generate()}"
        )

      assert json_response(conn, 401)
    end
  end

  describe "POST /api/workflows/:from_workflow_id/transitions" do
    setup :setup_authenticated

    test "creates transition and returns 201", %{
      conn: conn,
      workflow1: workflow1,
      workflow2: workflow2
    } do
      conn =
        post(conn, ~p"/api/workflows/#{workflow1.id}/transitions", %{
          to_workflow_id: workflow2.id,
          label: "promote"
        })

      assert %{
               "data" => %{
                 "id" => _id,
                 "from_workflow_id" => from_id,
                 "to_workflow_id" => to_id,
                 "label" => "promote"
               }
             } = json_response(conn, 201)

      assert from_id == workflow1.id
      assert to_id == workflow2.id
    end

    test "creates transition with target_step_id", %{
      conn: conn,
      workflow1: workflow1,
      workflow2: workflow2
    } do
      {:ok, step} = WorkflowSteps.insert(workflow2, %{name: "Review Step", step_order: 1})

      conn =
        post(conn, ~p"/api/workflows/#{workflow1.id}/transitions", %{
          to_workflow_id: workflow2.id,
          target_step_id: step.id
        })

      assert %{
               "data" => %{
                 "target_step_id" => target_step_id
               }
             } = json_response(conn, 201)

      assert target_step_id == step.id
    end

    test "returns 422 for missing to_workflow_id", %{conn: conn, workflow1: workflow1} do
      conn = post(conn, ~p"/api/workflows/#{workflow1.id}/transitions", %{label: "test"})
      assert %{"errors" => _} = json_response(conn, 422)
    end

    test "returns 422 for duplicate transition", %{
      conn: conn,
      workflow1: workflow1,
      workflow2: workflow2,
      project: project
    } do
      {:ok, _} =
        WorkflowTransitions.insert(workflow1.user_id, %{
          project_id: project.id,
          from_workflow_id: workflow1.id,
          to_workflow_id: workflow2.id
        })

      conn =
        post(conn, ~p"/api/workflows/#{workflow1.id}/transitions", %{
          to_workflow_id: workflow2.id
        })

      assert %{"errors" => _} = json_response(conn, 422)
    end

    test "returns 404 for another user's workflow", %{conn: conn, workflow2: workflow2} do
      other_user =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      {:ok, other_project} = Projects.insert(other_user, %{name: "Other Project"})
      {:ok, other_workflow} = Workflows.insert(other_project, %{name: "Other Workflow"})

      conn =
        post(conn, ~p"/api/workflows/#{other_workflow.id}/transitions", %{
          to_workflow_id: workflow2.id
        })

      assert json_response(conn, 404)
    end
  end

  describe "DELETE /api/workflows/:from_workflow_id/transitions/:id" do
    setup :setup_authenticated

    test "deletes transition and returns 204", %{
      conn: conn,
      workflow1: workflow1,
      workflow2: workflow2,
      project: project
    } do
      {:ok, transition} =
        WorkflowTransitions.insert(workflow1.user_id, %{
          project_id: project.id,
          from_workflow_id: workflow1.id,
          to_workflow_id: workflow2.id
        })

      conn = delete(conn, ~p"/api/workflows/#{workflow1.id}/transitions/#{transition.id}")
      assert response(conn, 204)

      # Verify it's deleted
      assert {:error, :not_found} = WorkflowTransitions.get(transition.id)
    end

    test "returns 404 for nonexistent transition", %{conn: conn, workflow1: workflow1} do
      conn = delete(conn, ~p"/api/workflows/#{workflow1.id}/transitions/#{Ecto.UUID.generate()}")
      assert json_response(conn, 404)
    end

    test "returns 404 for transition belonging to different workflow", %{
      conn: conn,
      workflow1: workflow1,
      workflow2: workflow2,
      project: project
    } do
      {:ok, workflow3} = Workflows.insert(project, %{name: "Third Workflow"})

      {:ok, transition} =
        WorkflowTransitions.insert(workflow1.user_id, %{
          project_id: project.id,
          from_workflow_id: workflow2.id,
          to_workflow_id: workflow3.id
        })

      # Try to delete transition via wrong from_workflow_id
      conn = delete(conn, ~p"/api/workflows/#{workflow1.id}/transitions/#{transition.id}")
      assert json_response(conn, 404)
    end

    test "returns 404 for another user's transition", %{conn: conn} do
      other_user =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      {:ok, other_project} = Projects.insert(other_user, %{name: "Other Project"})
      {:ok, other_workflow1} = Workflows.insert(other_project, %{name: "Other Workflow 1"})
      {:ok, other_workflow2} = Workflows.insert(other_project, %{name: "Other Workflow 2"})

      {:ok, transition} =
        WorkflowTransitions.insert(other_user.id, %{
          project_id: other_project.id,
          from_workflow_id: other_workflow1.id,
          to_workflow_id: other_workflow2.id
        })

      conn = delete(conn, ~p"/api/workflows/#{other_workflow1.id}/transitions/#{transition.id}")
      assert json_response(conn, 404)
    end
  end
end
