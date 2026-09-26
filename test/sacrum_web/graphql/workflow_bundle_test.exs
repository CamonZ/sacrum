defmodule SacrumWeb.Graphql.WorkflowBundleTest do
  use SacrumWeb.ConnCase

  alias Sacrum.Accounts

  test "imports a workflow bundle through the authenticated GraphQL mutation", %{
    conn: conn
  } do
    user = create_user(%{email: "bundle-graphql@example.com", username: "bundle_graphql"})
    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "GraphQL Bundle Project"})

    bundle = %{
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

  test "returns imported structured inference step config", %{conn: conn} do
    user = create_user(%{email: "bundle-si@example.com", username: "bundle_si"})
    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Structured Bundle Project"})

    state = %{"title" => "{{ task.title }}", "labels" => ["a", "b"]}

    questions = %{
      "risky" => %{"type" => "noul", "instructions" => "Is the change risky?"},
      "size" => %{
        "type" => "score",
        "instructions" => "How large is it?",
        "criteria" => ["small", "large"]
      }
    }

    bundle = %{
      "workflows" => [
        %{
          "workflow_ref" => "triage",
          "name" => "Triage",
          "steps" => [
            %{
              "step_ref" => "classify",
              "name" => "Classify",
              "step_type" => "structured_inference",
              "config" => %{
                "provider" => "typesafe",
                "model" => "system-one",
                "state" => state,
                "questions" => questions
              }
            }
          ]
        }
      ]
    }

    result =
      conn
      |> authenticate(user)
      |> post("/graphql", %{
        "query" => """
          mutation {
            importWorkflowBundle(
              projectId: "#{project.id}"
              bundle: #{Jason.encode!(Jason.encode!(bundle))}
            ) {
              workflowSteps {
                stepType
                config {
                  ... on StructuredInferenceStepConfig { provider model state questions }
                }
              }
            }
          }
        """
      })
      |> json_response(200)

    assert result["errors"] == nil

    assert [%{"stepType" => "structured_inference", "config" => config}] =
             result["data"]["importWorkflowBundle"]["workflowSteps"]

    assert config == %{
             "provider" => "typesafe",
             "model" => "system-one",
             "state" => state,
             "questions" => questions
           }
  end
end
