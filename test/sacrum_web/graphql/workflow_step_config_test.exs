defmodule SacrumWeb.Graphql.WorkflowStepConfigTest do
  use SacrumWeb.ConnCase

  alias Sacrum.Accounts

  @config_fields """
  stepType
  config {
    __typename
    ... on LlmInferenceStepConfig { version prompt agents skills agentConfig outputSchema }
    ... on WaitChildrenStepConfig { version outputSchema }
  }
  """

  setup do
    user = create_user()
    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Config Project"})
    {:ok, workflow} = Accounts.Workflows.insert(user.id, project.id, %{name: "Config"})
    %{user: user, workflow: workflow}
  end

  test "createWorkflowStep accepts a typed config and exposes it",
       %{conn: conn, user: user, workflow: workflow} do
    config = %{"prompt" => "Implement {{ task.title }}", "agents" => ["implementer"]}

    result =
      conn
      |> authenticate(user)
      |> graphql("""
        mutation {
          createWorkflowStep(
            workflowId: "#{workflow.id}"
            name: "Implement"
            stepType: "llm_inference"
            config: #{json_arg(config)}
          ) { #{@config_fields} }
        }
      """)
      |> json_response(200)

    assert result["data"]["createWorkflowStep"] == %{
             "stepType" => "llm_inference",
             "config" => %{
               "__typename" => "LlmInferenceStepConfig",
               "version" => 1,
               "prompt" => "Implement {{ task.title }}",
               "agents" => ["implementer"],
               "skills" => [],
               "agentConfig" => %{},
               "outputSchema" => nil
             }
           }
  end

  test "updateWorkflowStep patches the config and rejects a step type change",
       %{conn: conn, user: user, workflow: workflow} do
    {:ok, step} =
      Accounts.WorkflowSteps.insert(workflow, %{
        name: "Implement",
        config: %{"prompt" => "Go", "output_schema" => %{"type" => "object"}}
      })

    patched =
      conn
      |> authenticate(user)
      |> graphql("""
        mutation {
          updateWorkflowStep(id: "#{step.id}", config: #{json_arg(%{"agents" => ["worker"]})}) {
            #{@config_fields}
          }
        }
      """)
      |> json_response(200)

    assert %{
             "stepType" => "llm_inference",
             "config" => %{
               "prompt" => "Go",
               "outputSchema" => %{"type" => "object"},
               "agents" => ["worker"]
             }
           } = patched["data"]["updateWorkflowStep"]

    retyped =
      conn
      |> recycle()
      |> authenticate(user)
      |> graphql("""
        mutation {
          updateWorkflowStep(id: "#{step.id}", stepType: "wait_children") { id }
        }
      """)
      |> json_response(200)

    assert [%{"message" => "step_type: cannot be changed; create a new step instead"}] =
             retyped["errors"]
  end

  test "config errors are path-aware and null-config steps expose null",
       %{conn: conn, user: user, workflow: workflow} do
    rejected =
      conn
      |> authenticate(user)
      |> graphql("""
        mutation {
          createWorkflowStep(
            workflowId: "#{workflow.id}"
            name: "Bad"
            stepType: "llm_inference"
            config: #{json_arg(%{"temperature" => 1})}
          ) { id }
        }
      """)
      |> json_response(200)

    assert [%{"message" => "config: $.temperature: is not supported for llm_inference steps"}] =
             rejected["errors"]

    gate =
      conn
      |> authenticate(user)
      |> graphql("""
        mutation {
          createWorkflowStep(workflowId: "#{workflow.id}", name: "Gate", stepType: "human_input") {
            stepType config { __typename }
          }
        }
      """)
      |> json_response(200)

    assert gate["data"]["createWorkflowStep"] == %{"stepType" => "human_input", "config" => nil}
  end

  defp graphql(conn, query), do: post(conn, "/graphql", %{"query" => query})

  defp json_arg(value), do: Jason.encode!(Jason.encode!(value))

  test "step executions expose the config they ran with and no prompt",
       %{conn: conn, user: user, workflow: workflow} do
    fields = %{"type" => "object", "properties" => %{"ok" => %{"type" => "boolean"}}}

    {:ok, step} =
      Accounts.WorkflowSteps.insert(workflow, %{
        name: "Judge",
        step_type: "structured_inference",
        config: %{"provider" => "typesafe", "model" => "jev", "state" => "x", "fields" => fields}
      })

    {:ok, task} =
      Accounts.Tasks.insert(user.id, workflow.project_id, %{title: "T", level: "task"})

    {:ok, execution} =
      Accounts.StepExecutions.insert(user.id, %{
        task_id: task.id,
        project_id: task.project_id,
        step_id: step.id,
        step_name: step.name,
        status: "started"
      })

    authed = authenticate(conn, user)

    result =
      authed
      |> graphql("""
        mutation {
          updateStepExecution(id: "#{execution.id}", status: "in_progress") {
            config {
              __typename
              ... on StructuredInferenceStepConfig { version provider model state fields }
            }
          }
        }
      """)
      |> json_response(200)

    assert result["data"]["updateStepExecution"]["config"] == %{
             "__typename" => "StructuredInferenceStepConfig",
             "version" => 1,
             "provider" => "typesafe",
             "model" => "jev",
             "state" => "x",
             "fields" => fields
           }

    result =
      authed
      |> graphql("""
        mutation { updateStepExecution(id: "#{execution.id}", prompt: "x") { id } }
      """)
      |> json_response(200)

    assert [%{"message" => message}] = result["errors"]
    assert message =~ "Unknown argument \"prompt\""
  end
end
