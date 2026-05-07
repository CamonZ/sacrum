defmodule SacrumWeb.GraphQL.HumanInputExecutionTest do
  use SacrumWeb.ConnCase, async: true

  alias Sacrum.Accounts
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.StepExecution

  defp graphql(conn, query) do
    post(conn, "/graphql", %{"query" => query})
  end

  test "updateStepExecution cannot complete or fill waiting human_input executions", %{
    conn: conn
  } do
    suffix = System.unique_integer([:positive])

    user =
      create_user(%{
        email: "human-input-graphql-#{suffix}@example.com",
        username: "human_input_graphql_#{suffix}"
      })

    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Human Input API"})
    {:ok, workflow} = Accounts.Workflows.insert(user.id, project.id, %{name: "Workflow"})
    {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})

    {:ok, step} =
      Accounts.WorkflowSteps.insert(user.id, %{
        "workflow_id" => workflow.id,
        "project_id" => project.id,
        "name" => "Human Input",
        "step_type" => "human_input"
      })

    {:ok, execution} =
      Accounts.StepExecutions.insert(user.id, %{
        task_id: task.id,
        workflow_id: workflow.id,
        step_id: step.id,
        project_id: project.id,
        step_name: step.name,
        status: "waiting"
      })

    result =
      conn
      |> authenticate(user)
      |> graphql("""
        mutation {
          updateStepExecution(
            id: "#{execution.id}"
            status: "completed"
            output: "{\\"approved\\":true}"
          ) { id status output }
        }
      """)
      |> json_response(200)

    assert result["data"]["updateStepExecution"] == nil
    assert [_ | _] = result["errors"]

    reloaded = Repo.get!(StepExecution, execution.id)
    assert reloaded.status == "waiting"
    assert reloaded.output == nil
  end
end
