defmodule Sacrum.Repo.WorkflowStepRoutingTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo
  alias Sacrum.Repo.{Projects, StepTransitions, Users, WorkflowSteps, Workflows}
  alias Sacrum.Repo.Schemas.WorkflowStep

  @valid_user_attrs %{
    email: "workflow_step_routing_test@example.com",
    username: "workflow_step_routing_test",
    password: "password123"
  }

  @valid_attrs %{
    name: "Route",
    goal: "Select the next step",
    step_order: 1
  }

  test "creates and updates a route draft before setting its config" do
    workflow = create_workflow()
    destination = create_step(workflow, "Destination", 2)

    assert {:ok, route} =
             WorkflowSteps.insert(
               workflow,
               Map.merge(@valid_attrs, %{step_type: "route", config: %{}})
             )

    assert route.config.route_config == nil

    config = route_config(destination.id)

    assert {:ok, configured} =
             WorkflowSteps.update(route, %{config: %{"route_config" => config}})

    assert configured.config.route_config == config
    assert configured.step_type == :route

    assert {:ok, draft} =
             WorkflowSteps.update(configured, %{
               config: %{"route_config" => nil}
             })

    assert draft.config.route_config == nil
    assert draft.step_type == :route

    assert {:ok, configured_again} =
             WorkflowSteps.update(draft, %{config: %{"route_config" => config}})

    assert configured_again.config.route_config == config
    assert configured_again.step_type == :route
  end

  test "accepts a configured route while its graph edges are still being authored" do
    workflow = create_workflow()
    destination = create_step(workflow, "Destination", 2)
    config = route_config(destination.id)

    assert {:ok, route} =
             WorkflowSteps.insert(
               workflow,
               Map.merge(@valid_attrs, %{step_type: "route", config: %{"route_config" => config}})
             )

    assert route.config.route_config == config
  end

  test "rejects malformed route_config" do
    workflow = create_workflow()
    destination = create_step(workflow, "Destination", 2)

    assert {:error, changeset} =
             WorkflowSteps.insert(
               workflow,
               Map.merge(@valid_attrs, %{
                 step_type: "route",
                 config: %{"route_config" => Map.put(route_config(destination.id), "version", 2)}
               })
             )

    assert %{config: %{route_config: ["$.version: only version 1 is supported"]}} =
             errors_on(changeset)
  end

  test "stores only route_config in a route config" do
    workflow = create_workflow()
    destination = create_step(workflow, "Destination", 2)
    string_attrs = Map.new(@valid_attrs, fn {key, value} -> {to_string(key), value} end)

    for attrs <- [
          Map.merge(@valid_attrs, %{
            step_type: "route",
            config: %{"route_config" => route_config(destination.id)}
          }),
          Map.merge(string_attrs, %{
            "step_type" => "route",
            "config" => %{"route_config" => route_config(destination.id)}
          })
        ] do
      assert {:ok, step} = WorkflowSteps.insert(workflow, attrs)
      assert step.config == %WorkflowStep.Config.Route{route_config: route_config(destination.id)}
    end
  end

  test "still treats a whitespace goal as empty" do
    workflow = create_workflow()

    assert {:ok, step} =
             WorkflowSteps.insert(workflow, Map.merge(@valid_attrs, %{goal: "   "}))

    assert step.goal == nil
  end

  test "repairs a legacy null-config route before adding its graph edges" do
    workflow = create_workflow()

    source =
      create_step(workflow, "Source", 1, config: %{"output_schema" => predecessor_schema()})

    destination = create_step(workflow, "Destination", 2)

    route =
      Repo.insert!(%WorkflowStep{
        workflow_id: workflow.id,
        project_id: workflow.project_id,
        user_id: workflow.user_id,
        name: "Legacy route",
        step_order: 3,
        step_type: :route
      })

    assert {:ok, configured} =
             WorkflowSteps.update(route, %{
               config: %{"route_config" => route_config(destination.id)}
             })

    assert configured.config.route_config == route_config(destination.id)

    assert {:ok, _incoming} =
             StepTransitions.insert(workflow.user_id, %{
               from_step_id: source.id,
               to_step_id: route.id,
               project_id: workflow.project_id
             })

    assert {:ok, _outgoing} =
             StepTransitions.insert(workflow.user_id, %{
               from_step_id: route.id,
               to_step_id: destination.id,
               project_id: workflow.project_id
             })
  end

  test "does not defer a configured target that does not exist in the workflow" do
    workflow = create_workflow()

    source =
      create_step(workflow, "Source", 1, config: %{"output_schema" => predecessor_schema()})

    route =
      create_step(workflow, "Route", 2,
        step_type: "route",
        config: %{"route_config" => route_config(Ecto.UUID.generate())}
      )

    assert {:error, changeset} =
             StepTransitions.insert(workflow.user_id, %{
               from_step_id: source.id,
               to_step_id: route.id,
               project_id: workflow.project_id
             })

    assert %{route_config: [message]} = errors_on(changeset)
    assert message =~ "must be an outgoing step transition"
  end

  defp create_workflow do
    {:ok, user} = Users.insert(@valid_user_attrs)
    {:ok, project} = Projects.insert(user, %{name: "Routing Project"})
    {:ok, workflow} = Workflows.insert(project, %{name: "Routing Workflow"})
    workflow
  end

  defp create_step(workflow, name, step_order, attrs \\ []) do
    {:ok, step} =
      WorkflowSteps.insert(
        workflow,
        Map.merge(%{name: name, step_order: step_order}, Map.new(attrs))
      )

    step
  end

  defp route_config(target_id) do
    %{
      "version" => 1,
      "match_policy" => "exactly_one",
      "rules" => [
        %{
          "id" => "high_priority",
          "when" => %{"ref" => "task.tags", "op" => "contains", "value" => "priority"},
          "transition" => %{"type" => "intra_workflow", "step_id" => target_id}
        }
      ],
      "default" => %{
        "transition" => %{"type" => "intra_workflow", "step_id" => target_id}
      }
    }
  end

  defp predecessor_schema do
    %{
      "type" => "object",
      "properties" => %{
        "route" => %{
          "type" => "object",
          "properties" => %{
            "result" => %{"type" => "string", "enum" => ["approved"]},
            "handoff" => %{
              "type" => "object",
              "properties" => %{},
              "required" => [],
              "additionalProperties" => false
            }
          },
          "required" => ["result", "handoff"],
          "additionalProperties" => false
        }
      },
      "required" => ["route"],
      "additionalProperties" => false
    }
  end
end
