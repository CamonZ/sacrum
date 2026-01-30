defmodule SacrumWeb.WorkflowControllerTest do
  use SacrumWeb.ConnCase, async: true

  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Workflows

  defp setup_authenticated(%{conn: conn}) do
    user = create_user()
    conn = authenticate(conn, user)
    {:ok, project} = Projects.insert(user, %{name: "Test Project"})
    %{conn: conn, user: user, project: project}
  end

  describe "unauthenticated requests" do
    test "returns 401 without auth header", %{conn: conn} do
      conn = get(conn, ~p"/api/workflows")
      assert json_response(conn, 401)
    end
  end

  describe "GET /api/workflows" do
    setup :setup_authenticated

    test "returns 200 with workflow list filtered by project_id", %{
      conn: conn,
      project: project
    } do
      {:ok, _} = Workflows.insert(project, %{name: "Workflow 1"})
      {:ok, _} = Workflows.insert(project, %{name: "Workflow 2"})

      conn = get(conn, ~p"/api/workflows?project_id=#{project.id}")

      assert %{"data" => workflows} = json_response(conn, 200)
      assert length(workflows) == 2
    end

    test "returns all workflows across projects when no project_id", %{
      conn: conn,
      project: project
    } do
      {:ok, _} = Workflows.insert(project, %{name: "Workflow 1"})

      conn = get(conn, ~p"/api/workflows")
      assert %{"data" => workflows} = json_response(conn, 200)
      assert length(workflows) >= 1
    end

    test "returns empty list when no workflows", %{conn: conn, project: project} do
      conn = get(conn, ~p"/api/workflows?project_id=#{project.id}")
      assert %{"data" => []} = json_response(conn, 200)
    end

    test "returns 404 for another user's project", %{conn: conn} do
      other_user =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      {:ok, other_project} = Projects.insert(other_user, %{name: "Other"})

      conn = get(conn, ~p"/api/workflows?project_id=#{other_project.id}")
      assert json_response(conn, 404)
    end
  end

  describe "GET /api/workflows/:id" do
    setup :setup_authenticated

    test "returns 200 with workflow JSON", %{conn: conn, project: project} do
      {:ok, workflow} = Workflows.insert(project, %{name: "My Workflow", description: "Desc"})

      conn = get(conn, ~p"/api/workflows/#{workflow.id}")

      assert %{
               "data" => %{
                 "id" => id,
                 "name" => "My Workflow",
                 "description" => "Desc"
               }
             } = json_response(conn, 200)

      assert id == workflow.id
    end

    test "returns 404 for nonexistent workflow", %{conn: conn} do
      conn = get(conn, ~p"/api/workflows/#{Ecto.UUID.generate()}")
      assert json_response(conn, 404)
    end
  end

  describe "POST /api/workflows" do
    setup :setup_authenticated

    test "returns 201 with workflow JSON for valid params", %{conn: conn, project: project} do
      conn =
        post(conn, ~p"/api/workflows", %{
          project_id: project.id,
          name: "New Workflow",
          description: "A new workflow"
        })

      assert %{
               "data" => %{
                 "id" => _id,
                 "name" => "New Workflow",
                 "description" => "A new workflow"
               }
             } = json_response(conn, 201)
    end

    test "returns 422 with missing name", %{conn: conn, project: project} do
      conn = post(conn, ~p"/api/workflows", %{project_id: project.id})
      assert %{"errors" => %{"name" => _}} = json_response(conn, 422)
    end
  end

  describe "PATCH /api/workflows/:id" do
    setup :setup_authenticated

    test "updates and returns 200", %{conn: conn, project: project} do
      {:ok, workflow} = Workflows.insert(project, %{name: "Original"})

      conn =
        patch(conn, ~p"/api/workflows/#{workflow.id}", %{
          name: "Updated",
          description: "New desc"
        })

      assert %{
               "data" => %{
                 "name" => "Updated",
                 "description" => "New desc"
               }
             } = json_response(conn, 200)
    end
  end

  describe "PATCH /api/workflows/:id with transitions" do
    setup :setup_authenticated

    test "returns workflow with transitions in response", %{conn: conn, project: project} do
      {:ok, wf1} = Workflows.insert(project, %{name: "Source"})
      {:ok, wf2} = Workflows.insert(project, %{name: "Target"})

      conn =
        patch(conn, ~p"/api/workflows/#{wf1.id}", %{
          transitions: [
            %{to_workflow_id: wf2.id, label: "on_done"}
          ]
        })

      assert %{
               "data" => %{
                 "transitions" => [
                   %{
                     "to_workflow_id" => to_id,
                     "label" => "on_done"
                   }
                 ]
               }
             } = json_response(conn, 200)

      assert to_id == wf2.id
    end

    test "empty transitions list removes all existing transitions", %{
      conn: conn,
      project: project
    } do
      {:ok, wf1} = Workflows.insert(project, %{name: "Source"})
      {:ok, wf2} = Workflows.insert(project, %{name: "Target"})

      alias Sacrum.Repo.WorkflowTransitions

      {:ok, _} =
        WorkflowTransitions.insert(wf1.user_id, %{
          from_workflow_id: wf1.id,
          to_workflow_id: wf2.id
        })

      conn = patch(conn, ~p"/api/workflows/#{wf1.id}", %{transitions: []})

      assert %{"data" => %{"transitions" => []}} = json_response(conn, 200)
    end

    test "returns 422 for duplicate to_workflow_id entries", %{conn: conn, project: project} do
      {:ok, wf1} = Workflows.insert(project, %{name: "Source"})
      {:ok, wf2} = Workflows.insert(project, %{name: "Target"})

      conn =
        patch(conn, ~p"/api/workflows/#{wf1.id}", %{
          transitions: [
            %{to_workflow_id: wf2.id, label: "first"},
            %{to_workflow_id: wf2.id, label: "second"}
          ]
        })

      assert json_response(conn, 422)
    end

    test "returns 422 for non-existent to_workflow_id", %{conn: conn, project: project} do
      {:ok, wf1} = Workflows.insert(project, %{name: "Source"})

      conn =
        patch(conn, ~p"/api/workflows/#{wf1.id}", %{
          transitions: [
            %{to_workflow_id: Ecto.UUID.generate(), label: "broken"}
          ]
        })

      assert json_response(conn, 422)
    end
  end

  describe "DELETE /api/workflows/:id" do
    setup :setup_authenticated

    test "returns 204", %{conn: conn, project: project} do
      {:ok, workflow} = Workflows.insert(project, %{name: "To Delete"})
      conn = delete(conn, ~p"/api/workflows/#{workflow.id}")
      assert response(conn, 204)
    end

    test "returns 404 for another user's workflow", %{conn: conn} do
      other_user =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      {:ok, other_project} = Projects.insert(other_user, %{name: "Other"})
      {:ok, workflow} = Workflows.insert(other_project, %{name: "Secret"})

      conn = delete(conn, ~p"/api/workflows/#{workflow.id}")
      assert json_response(conn, 404)
    end
  end
end
