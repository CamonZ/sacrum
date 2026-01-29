defmodule SacrumWeb.WorkflowTransitionControllerTest do
  use SacrumWeb.ConnCase, async: true

  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Workflows
  alias Sacrum.Repo.WorkflowTransitions
  alias Sacrum.Auth

  @valid_user_attrs %{
    email: "test@example.com",
    username: "testuser",
    password: "password123"
  }

  defp create_user do
    {:ok, user} = Users.insert(@valid_user_attrs)
    user
  end

  defp authenticate(conn, user) do
    {:ok, token, _api_token} = Auth.create_api_token(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp setup_authenticated(%{conn: conn}) do
    user = create_user()
    conn = authenticate(conn, user)
    {:ok, project} = Projects.insert(user, %{name: "Test Project"})
    %{conn: conn, user: user, project: project}
  end

  defp setup_workflows(%{project: project} = context) do
    {:ok, wf1} = Workflows.insert(project, %{name: "Workflow A"})
    {:ok, wf2} = Workflows.insert(project, %{name: "Workflow B"})
    Map.merge(context, %{wf1: wf1, wf2: wf2})
  end

  describe "GET /api/projects/:project_id/workflow-transitions" do
    setup [:setup_authenticated, :setup_workflows]

    test "returns all transitions for the project", ctx do
      {:ok, _} =
        WorkflowTransitions.insert(%{
          from_workflow_id: ctx.wf1.id,
          to_workflow_id: ctx.wf2.id,
          label: "on_done"
        })

      conn =
        get(ctx.conn, ~p"/api/projects/#{ctx.project.id}/workflow-transitions")

      assert %{"data" => transitions} = json_response(conn, 200)
      assert length(transitions) == 1
      assert hd(transitions)["from_workflow_name"] == "Workflow A"
      assert hd(transitions)["to_workflow_name"] == "Workflow B"
    end

    test "returns empty list when no transitions exist", ctx do
      conn =
        get(ctx.conn, ~p"/api/projects/#{ctx.project.id}/workflow-transitions")

      assert %{"data" => []} = json_response(conn, 200)
    end
  end

  describe "POST /api/projects/:project_id/workflow-transitions" do
    setup [:setup_authenticated, :setup_workflows]

    test "creates a transition between workflows", ctx do
      conn =
        post(ctx.conn, ~p"/api/projects/#{ctx.project.id}/workflow-transitions", %{
          from_workflow_id: ctx.wf1.id,
          to_workflow_id: ctx.wf2.id,
          label: "on_done"
        })

      assert %{"data" => %{"from_workflow_id" => _, "to_workflow_id" => _}} =
               json_response(conn, 201)
    end

    test "rejects duplicate from/to workflow pairs", ctx do
      {:ok, _} =
        WorkflowTransitions.insert(%{
          from_workflow_id: ctx.wf1.id,
          to_workflow_id: ctx.wf2.id
        })

      conn =
        post(ctx.conn, ~p"/api/projects/#{ctx.project.id}/workflow-transitions", %{
          from_workflow_id: ctx.wf1.id,
          to_workflow_id: ctx.wf2.id
        })

      assert json_response(conn, 422)
    end
  end

  describe "DELETE /api/projects/:project_id/workflow-transitions/:id" do
    setup [:setup_authenticated, :setup_workflows]

    test "deletes a transition", ctx do
      {:ok, transition} =
        WorkflowTransitions.insert(%{
          from_workflow_id: ctx.wf1.id,
          to_workflow_id: ctx.wf2.id
        })

      conn =
        delete(
          ctx.conn,
          ~p"/api/projects/#{ctx.project.id}/workflow-transitions/#{transition.id}"
        )

      assert response(conn, 204)
    end
  end

  describe "authentication" do
    test "returns 401 without auth token", %{conn: conn} do
      conn = get(conn, ~p"/api/projects/#{Ecto.UUID.generate()}/workflow-transitions")
      assert json_response(conn, 401)
    end
  end
end
