defmodule SacrumWeb.Graphql.WorkflowBundleTest do
  use SacrumWeb.ConnCase

  alias Sacrum.Accounts

  test "imports a workflow bundle through the authenticated GraphQL mutation", %{
    conn: conn
  } do
    user = create_user(%{email: "bundle-graphql@example.com", username: "bundle_graphql"})
    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "GraphQL Bundle Project"})

    bundle = %{
      "schema_version" => 1,
      "workflows" => [%{"workflow_ref" => "imported", "name" => "Imported GraphQL"}]
    }

    encoded_bundle = Jason.encode!(Jason.encode!(bundle))

    result =
      conn
      |> authenticate(user)
      |> post("/graphql", %{
        "query" => """
          mutation {
            importWorkflowBundle(
              projectId: "#{project.id}"
              bundle: #{encoded_bundle}
            ) {
              workflowCount
              stepCount
              workflowMappings
              stepMappings
            }
          }
        """
      })
      |> json_response(200)

    assert result["errors"] == nil
    assert result["data"]["importWorkflowBundle"]["workflowCount"] == 1
    assert result["data"]["importWorkflowBundle"]["stepCount"] == 0

    assert %{"imported" => imported_id} =
             result["data"]["importWorkflowBundle"]["workflowMappings"]

    assert result["data"]["importWorkflowBundle"]["stepMappings"] == %{"imported" => %{}}
    assert is_binary(imported_id)
  end
end
