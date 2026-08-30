defmodule SacrumWeb.Graphql.WorkflowStepRouteConfigTest do
  use SacrumWeb.ConnCase

  import Ecto.Query

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.FSMData
  alias Sacrum.Orchestrator.Routing.RouteStep
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{StepExecution, TaskRun}
  alias Sacrum.Routing.RouteConfig

  defp graphql(conn, query) do
    post(conn, "/graphql", %{"query" => query})
  end

  defp setup_user_and_project(_context) do
    user = create_user()
    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Route Config Project"})
    %{user: user, project: project}
  end

  describe "workflow step route_config contract" do
    setup [:setup_user_and_project]

    test "createWorkflowStep validates route_config through the changeset", %{
      conn: conn,
      user: user,
      project: project
    } do
      graph = unconfigured_route_graph(user, project)

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createWorkflowStep(
              workflowId: "#{graph.workflow.id}"
              name: "Configured on create"
              stepType: "route"
              prompt: "Keep this fallback"
              stepOrder: 4
              routeConfig: #{json_arg(routing_config(graph.destination.id))}
            ) { id prompt routeConfig }
          }
        """)
        |> json_response(200)

      assert result["data"]["createWorkflowStep"] == nil
      assert_route_config_error(result, "$.predecessors")
    end

    test "rejects routeConfig read and mutation by another user", %{
      conn: conn,
      user: user,
      project: project
    } do
      graph = configured_route_graph(user, project)
      other = create_user(%{email: "other-route@example.com", username: "other_route"})

      query =
        conn
        |> authenticate(other)
        |> graphql(~s|{ workflowStep(id: "#{graph.route.id}") { id routeConfig } }|)
        |> json_response(200)

      assert query["data"]["workflowStep"] == nil
      assert query["errors"] != nil

      mutation =
        conn
        |> recycle()
        |> authenticate(other)
        |> graphql("""
          mutation {
            updateWorkflowStep(
              id: "#{graph.route.id}"
              routeConfig: #{json_arg(routing_config(graph.destination.id))}
            ) { id routeConfig }
          }
        """)
        |> json_response(200)

      assert mutation["data"]["updateWorkflowStep"] == nil
      assert mutation["errors"] != nil

      assert {:ok, unchanged} =
               Accounts.WorkflowSteps.get_by(user.id, conditions: [id: graph.route.id])

      assert unchanged.route_config == graph.route.route_config
    end

    test "returns path-aware errors for invalid versions, keys, operators, handoffs, predecessors, and destinations",
         %{conn: conn, user: user, project: project} do
      graph = unconfigured_route_graph(user, project)
      valid = routing_config(graph.destination.id)

      conn = authenticate(conn, user)

      version_result =
        update_route_config(conn, user, graph.route.id, Map.put(valid, "version", 2))

      assert_route_config_error(version_result, "$.version")

      unknown_key_result =
        update_route_config(conn, user, graph.route.id, Map.put(valid, "unexpected", true))

      assert_route_config_error(unknown_key_result, "$.unexpected")

      operator_result =
        update_route_config(
          conn,
          user,
          graph.route.id,
          put_in(valid, ["rules", Access.at(0), "when", "op"], "matches")
        )

      assert_route_config_error(operator_result, "$.rules[0].when.op")

      malformed_handoff_result =
        update_route_config(
          conn,
          user,
          graph.route.id,
          put_in(valid, ["rules", Access.at(0), "handoff"], %{"note" => "{{ task.level"})
        )

      assert_route_config_error(malformed_handoff_result, "$.rules[0].handoff.note")

      unknown_handoff_result =
        update_route_config(
          conn,
          user,
          graph.route.id,
          put_in(valid, ["rules", Access.at(0), "handoff"], %{"note" => "{{ task.title }}"})
        )

      assert_route_config_error(unknown_handoff_result, "$.rules[0].handoff.note")

      predecessor_result = update_route_config(conn, user, graph.route.id, valid)
      assert_route_config_error(predecessor_result, "$.predecessors")

      configured = configured_route_graph(user, project)

      destination_result =
        update_route_config(
          conn,
          user,
          configured.route.id,
          routing_config(Ecto.UUID.generate())
        )

      assert_route_config_error(destination_result, "$.rules[0].transition.step_id")
    end

    test "reads the RouteAudit written by a local deterministic route commit", %{
      conn: conn,
      user: user,
      project: project
    } do
      committed = commit_local_route(user, project)

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          {
            stepExecution(id: "#{committed.execution.id}") {
              context
              transitionResult
              handoff
              output
            }
          }
        """)
        |> json_response(200)

      assert result["errors"] == nil
      data = result["data"]["stepExecution"]
      route = data["context"]["route"]

      assert route["mode"] == "deterministic"
      assert route["source_execution_id"] == committed.source_execution.id
      assert route["config_version"] == 1
      assert route["matched_rule_id"] == "approved"
      assert route["used_default"] == false
      assert route["context"]["previous_output"]["route"]["result"] == "approved"
      assert route["context"]["previous_output"]["route"]["handoff"] == committed.source_handoff
      assert data["handoff"] == committed.handoff
      refute data["handoff"] == committed.source_handoff
      refute Map.has_key?(data["handoff"], "type")
      refute Map.has_key?(data["handoff"], "step_id")
      refute Map.has_key?(data["handoff"], "workflow_id")

      assert Jason.decode!(data["transitionResult"]) == %{
               "dest_id" => committed.destination.id,
               "transition_type" => "intra_workflow"
             }
    end

    test "does not fabricate deterministic route provenance for non-route executions", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Ordinary task"})
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      {:ok, exec} =
        Accounts.StepExecutions.insert(user.id, %{
          task_id: task.id,
          workflow_id: wf.id,
          project_id: project.id,
          step_name: "Execute",
          step_type: "execute",
          status: "completed"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql(~s|{ stepExecution(id: "#{exec.id}") { context transitionResult handoff } }|)
        |> json_response(200)

      assert result["errors"] == nil

      assert result["data"]["stepExecution"] == %{
               "context" => %{},
               "transitionResult" => nil,
               "handoff" => nil
             }

      refute Map.has_key?(result["data"]["stepExecution"]["context"], "route")
    end
  end

  defp update_route_config(conn, user, route_id, route_config) do
    conn
    |> recycle()
    |> authenticate(user)
    |> graphql("""
      mutation {
        updateWorkflowStep(
          id: "#{route_id}"
          routeConfig: #{json_arg(route_config)}
        ) { id routeConfig }
      }
    """)
    |> json_response(200)
  end

  defp assert_route_config_error(result, path) do
    data = result["data"]["updateWorkflowStep"] || result["data"]["createWorkflowStep"]
    assert data == nil

    assert Enum.any?(result["errors"], fn error ->
             error["message"] =~ "route_config" and error["message"] =~ path
           end)
  end

  defp json_arg(value), do: Jason.encode!(Jason.encode!(value))

  defp unconfigured_route_graph(user, project) do
    {:ok, workflow} =
      Accounts.Workflows.insert(user.id, project.id, %{name: "Unconfigured route"})

    {:ok, source} =
      Accounts.WorkflowSteps.insert(workflow, %{
        name: "Source",
        step_order: 1,
        output_schema: predecessor_schema()
      })

    {:ok, route} =
      Accounts.WorkflowSteps.insert(workflow, %{
        name: "Route",
        step_order: 2,
        step_type: "route",
        prompt: "Fallback"
      })

    {:ok, destination} =
      Accounts.WorkflowSteps.insert(workflow, %{
        name: "Destination",
        step_order: 3
      })

    %{workflow: workflow, source: source, route: route, destination: destination}
  end

  defp configured_route_graph(user, project) do
    graph = unconfigured_route_graph(user, project)

    {:ok, _} =
      Accounts.StepTransitions.insert(user.id, %{
        from_step_id: graph.source.id,
        to_step_id: graph.route.id,
        project_id: project.id
      })

    {:ok, _} =
      Accounts.StepTransitions.insert(user.id, %{
        from_step_id: graph.route.id,
        to_step_id: graph.destination.id,
        project_id: project.id
      })

    {:ok, route} =
      Accounts.WorkflowSteps.update(graph.route, %{
        route_config: routing_config(graph.destination.id)
      })

    %{graph | route: route}
  end

  defp commit_local_route(user, project) do
    graph = configured_route_graph(user, project)
    {:ok, _} = Accounts.Workflows.update(graph.workflow, %{initial_step_id: graph.source.id})
    {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Route task"})
    {:ok, task} = Repo.TaskWorkflows.assign_workflow(task, graph.workflow)
    {:ok, task} = Repo.update(Ecto.Changeset.change(task, current_step_id: graph.route.id))

    {:ok, task_run} =
      Accounts.TaskRuns.insert(user.id, project.id, task.id, %{status: :executing})

    source_handoff = %{"review" => "needed"}
    handoff = rendered_route_handoff(source_handoff)

    {:ok, source_execution} =
      Accounts.StepExecutions.insert(user.id, %{
        task_id: task.id,
        project_id: project.id,
        workflow_id: graph.workflow.id,
        task_run_id: task_run.id,
        step_id: graph.source.id,
        step_name: graph.source.name,
        step_type: :execute,
        status: "completed",
        output:
          Jason.encode!(%{"route" => %{"result" => "approved", "handoff" => source_handoff}})
      })

    {:ok, task_run} =
      task_run
      |> TaskRun.update_changeset(%{latest_step_execution_id: source_execution.id})
      |> Repo.update()

    {:ok, program} = RouteConfig.decode(graph.route.route_config)

    data = %FSMData{
      user_id: user.id,
      project_id: project.id,
      task: task,
      task_run_id: task_run.id,
      workflow: graph.workflow,
      steps: %{
        graph.source.id => graph.source,
        graph.route.id => graph.route,
        graph.destination.id => graph.destination
      },
      transitions: %{
        graph.source.id => [graph.route.id],
        graph.route.id => [graph.destination.id]
      }
    }

    result = RouteStep.handle_deterministic_route_step(data, graph.route, program)
    assert elem(result, 0) in [:next_state, :stop]

    execution =
      Repo.one!(
        from(e in StepExecution,
          where:
            e.task_id == ^task.id and e.step_id == ^graph.route.id and e.status == "completed"
        )
      )

    %{
      destination: graph.destination,
      execution: execution,
      handoff: handoff,
      source_handoff: source_handoff,
      source_execution: source_execution
    }
  end

  defp routing_config(destination_id) do
    %{
      "version" => 1,
      "match_policy" => "exactly_one",
      "rules" => [
        %{
          "id" => "approved",
          "when" => %{
            "ref" => "previous_output.route.result",
            "op" => "eq",
            "value" => "approved"
          },
          "transition" => %{"type" => "intra_workflow", "step_id" => destination_id},
          "handoff" => route_handoff_template()
        }
      ],
      "default" => %{
        "transition" => %{"type" => "intra_workflow", "step_id" => destination_id},
        "handoff" => route_handoff_template()
      }
    }
  end

  defp route_handoff_template do
    %{
      "review" => "{{ previous_output.route.handoff.review }}",
      "result" => "{{ previous_output.route.result }}",
      "visit" => "{{ execution.step_visit_count }}"
    }
  end

  defp rendered_route_handoff(source_handoff) do
    %{
      "review" => source_handoff["review"],
      "result" => "approved",
      "visit" => 1
    }
  end

  defp predecessor_schema do
    %{
      "type" => "object",
      "properties" => %{
        "route" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["result", "handoff"],
          "properties" => %{
            "result" => %{"type" => "string", "enum" => ["approved"]},
            "handoff" => %{
              "type" => "object",
              "additionalProperties" => false,
              "required" => ["review"],
              "properties" => %{"review" => %{"type" => "string"}}
            }
          }
        }
      },
      "required" => ["route"],
      "additionalProperties" => false
    }
  end
end
