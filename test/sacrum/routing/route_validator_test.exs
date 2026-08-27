defmodule Sacrum.Routing.RouteValidatorTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts
  alias Sacrum.Repo
  alias Sacrum.Routing.RouteValidator

  setup do
    user = create_user()
    project = create_project(user)
    workflow = create_workflow(user, project, "Source")
    %{user: user, project: project, workflow: workflow}
  end

  test "accepts a route with a legal predecessor, exhaustive finite result branch, and intra target",
       context do
    source = create_step(context, "source", 1, output_schema: predecessor_schema(["approved"]))
    destination = create_step(context, "destination", 2)

    route = create_route(context, "route", 3)

    create_step_transition(context.user, source, route)
    create_step_transition(context.user, route, destination)

    route =
      configure_route(
        route,
        route_config(
          [result_rule("approved", intra_target(destination.id))],
          intra_target(destination.id)
        )
      )

    assert :ok = RouteValidator.validate(route)
  end

  test "rejects an existing but unconnected intra-workflow destination", context do
    source = create_step(context, "source", 1, output_schema: predecessor_schema(["approved"]))
    disconnected = create_step(context, "disconnected", 2)

    route = create_route(context, "route", 3)

    create_step_transition(context.user, source, route)

    route =
      persist_invalid_route_config(
        route,
        route_config(
          [result_rule("approved", intra_target(disconnected.id))],
          intra_target(disconnected.id)
        )
      )

    assert {:error, %{code: :route_target_invalid, path: "$.rules[0].transition.step_id"}} =
             RouteValidator.validate(route)
  end

  test "validates inter-workflow transition targets and destination entry configuration",
       context do
    source = create_step(context, "source", 1, output_schema: predecessor_schema(["approved"]))
    destination_workflow = create_workflow(context.user, context.project, "Destination")

    destination =
      create_step(
        %{context | workflow: destination_workflow},
        "destination",
        1
      )

    {:ok, destination_workflow} =
      Accounts.Workflows.update(destination_workflow, %{initial_step_id: destination.id})

    route = create_route(context, "route", 2)

    create_step_transition(context.user, source, route)
    create_workflow_transition(context.user, context.workflow, destination_workflow)

    route =
      configure_route(
        route,
        route_config(
          [result_rule("approved", inter_target(destination_workflow.id))],
          inter_target(destination_workflow.id)
        )
      )

    assert :ok = RouteValidator.validate(route)

    other_step = create_step(context, "other", 3)

    {:ok, transition} =
      Repo.WorkflowTransitions.get_by(
        conditions: [
          from_workflow_id: context.workflow.id,
          to_workflow_id: destination_workflow.id
        ]
      )

    assert {:ok, _transition} =
             Repo.update(Ecto.Changeset.change(transition, %{target_step_id: other_step.id}))

    assert {:error, %{code: :route_target_invalid, path: "$.rules[0].transition.workflow_id"}} =
             RouteValidator.validate(route)
  end

  test "rejects uncovered finite result and task-level combinations", context do
    source =
      create_step(context, "source", 1,
        output_schema: predecessor_schema(["approved", "rejected"])
      )

    destination = create_step(context, "destination", 2)

    route = create_route(context, "route", 3)

    create_step_transition(context.user, source, route)
    create_step_transition(context.user, route, destination)

    route =
      persist_invalid_route_config(
        route,
        route_config([result_rule("approved", intra_target(destination.id))])
      )

    assert {:error, %{code: :route_config_uncovered, path: "$.rules"}} =
             RouteValidator.validate(route)
  end

  test "rejects statically overlapping closed-domain rules", context do
    source = create_step(context, "source", 1, output_schema: predecessor_schema(["approved"]))
    destination = create_step(context, "destination", 2)

    route = create_route(context, "route", 3)

    create_step_transition(context.user, source, route)
    create_step_transition(context.user, route, destination)

    route =
      persist_invalid_route_config(
        route,
        route_config(
          [
            level_rule("ticket", intra_target(destination.id)),
            level_rule("ticket-again", intra_target(destination.id))
          ],
          intra_target(destination.id)
        )
      )

    assert {:error, %{code: :route_config_ambiguous, path: "$.rules[1].when"}} =
             RouteValidator.validate(route)
  end

  defp create_user do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Repo.Users.insert(%{
        email: "route_validator_#{suffix}@example.com",
        username: "route_validator_#{suffix}",
        password: "password123"
      })

    user
  end

  defp create_project(user) do
    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Route Validator"})
    project
  end

  defp create_workflow(user, project, name) do
    {:ok, workflow} = Accounts.Workflows.insert(user.id, project.id, %{name: name})
    workflow
  end

  defp create_step(%{user: user, workflow: workflow}, name, order, opts \\ []) do
    attrs = %{
      "name" => name,
      "step_order" => order,
      "prompt" => "Prompt for #{name}",
      "workflow_id" => workflow.id,
      "project_id" => workflow.project_id
    }

    attrs =
      opts
      |> Enum.into(%{})
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> then(&Map.merge(attrs, &1))

    {:ok, step} = Accounts.WorkflowSteps.insert(user.id, attrs)
    step
  end

  defp create_route(context, name, order) do
    create_step(context, name, order, step_type: "route")
  end

  defp configure_route(route, route_config) do
    {:ok, route} = Accounts.WorkflowSteps.update(route, %{route_config: route_config})
    route
  end

  # Validator unit tests deliberately persist invalid states through the raw
  # Ecto repository so they can assert the validator's diagnostics. Production
  # mutations go through the guarded repository APIs.
  defp persist_invalid_route_config(route, route_config) do
    {:ok, route} = Repo.update(Ecto.Changeset.change(route, %{route_config: route_config}))
    route
  end

  defp create_step_transition(user, from_step, to_step) do
    {:ok, transition} =
      Accounts.StepTransitions.insert(user.id, %{
        "from_step_id" => from_step.id,
        "to_step_id" => to_step.id,
        "project_id" => from_step.project_id
      })

    transition
  end

  defp create_workflow_transition(user, from_workflow, to_workflow) do
    {:ok, transition} =
      Accounts.WorkflowTransitions.insert(user.id, %{
        "from_workflow_id" => from_workflow.id,
        "to_workflow_id" => to_workflow.id,
        "project_id" => from_workflow.project_id
      })

    transition
  end

  defp route_config(rules, default \\ nil) do
    config = %{"version" => 1, "match_policy" => "exactly_one", "rules" => rules}

    if is_nil(default), do: config, else: Map.put(config, "default", %{"transition" => default})
  end

  defp result_rule(result, target) do
    %{
      "id" => "result-#{result}",
      "when" => %{"ref" => "previous_output.route.result", "op" => "eq", "value" => result},
      "transition" => target
    }
  end

  defp level_rule(id, target) do
    %{
      "id" => id,
      "when" => %{"ref" => "task.level", "op" => "eq", "value" => "ticket"},
      "transition" => target
    }
  end

  defp intra_target(step_id), do: %{"type" => "intra_workflow", "step_id" => step_id}
  defp inter_target(workflow_id), do: %{"type" => "inter_workflow", "workflow_id" => workflow_id}

  defp predecessor_schema(result_values) do
    %{
      "type" => "object",
      "properties" => %{
        "route" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["result", "handoff"],
          "properties" => %{
            "result" => %{"type" => "string", "enum" => result_values},
            "handoff" => %{
              "type" => "object",
              "additionalProperties" => false,
              "required" => [],
              "properties" => %{}
            }
          }
        }
      },
      "required" => ["route"],
      "additionalProperties" => false
    }
  end
end
