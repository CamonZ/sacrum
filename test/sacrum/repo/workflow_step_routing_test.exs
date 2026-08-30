defmodule Sacrum.Repo.WorkflowStepRoutingTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.{Projects, Users, WorkflowSteps, Workflows}
  alias Sacrum.Routing.Contract

  @valid_user_attrs %{
    email: "workflow_step_routing_test@example.com",
    username: "workflow_step_routing_test",
    password: "password123"
  }

  @valid_attrs %{
    name: "Route",
    goal: "Select the next step",
    agents: ["router"],
    skills: ["routing"],
    agent_config: %{},
    step_order: 1
  }

  test "keeps prompt-only routes on the legacy output contract" do
    workflow = create_workflow()

    assert {:ok, step} =
             WorkflowSteps.insert(
               workflow,
               Map.merge(@valid_attrs, %{step_type: "route", prompt: "Choose a destination"})
             )

    assert step.route_config == nil
    assert step.output_schema == Contract.output_schema()
  end

  test "rejects a route_config until its graph prerequisites exist" do
    workflow = create_workflow()
    route_config = route_config()

    assert {:error, changeset} =
             WorkflowSteps.insert(
               workflow,
               Map.merge(@valid_attrs, %{
                 step_type: "route",
                 prompt: "Choose a destination",
                 route_config: route_config
               })
             )

    assert %{route_config: [message]} = errors_on(changeset)
    assert message =~ "$.predecessors"
  end

  test "does not use a leftover prompt to accept an invalid route_config" do
    workflow = create_workflow()
    route_config = route_config()

    assert {:error, changeset} =
             WorkflowSteps.insert(
               workflow,
               Map.merge(@valid_attrs, %{
                 step_type: "route",
                 prompt: "Choose a destination",
                 route_config: route_config
               })
             )

    assert %{route_config: [message]} = errors_on(changeset)
    assert message =~ "$.predecessors"
  end

  test "persists a promptless unconfigured route as an authoring draft" do
    workflow = create_workflow()

    assert {:ok, draft} =
             WorkflowSteps.insert(
               workflow,
               Map.merge(@valid_attrs, %{step_type: "route", prompt: nil})
             )

    assert draft.prompt == nil
    assert draft.route_config == nil
    assert draft.output_schema == nil
  end

  test "preserves an empty prompt as distinct from a cleared draft prompt" do
    workflow = create_workflow()
    string_attrs = Map.new(@valid_attrs, fn {key, value} -> {to_string(key), value} end)

    for attrs <- [
          Map.merge(@valid_attrs, %{step_type: "route", prompt: ""}),
          Map.merge(string_attrs, %{"step_type" => "route", "prompt" => ""})
        ] do
      assert {:ok, step} = WorkflowSteps.insert(workflow, attrs)
      assert step.prompt == ""
      assert step.output_schema == Contract.output_schema()
    end
  end

  test "preserves a whitespace prompt as a non-null draft prompt" do
    workflow = create_workflow()

    assert {:ok, route} =
             WorkflowSteps.insert(
               workflow,
               Map.merge(@valid_attrs, %{step_type: "route", prompt: "   "})
             )

    assert route.prompt == "   "
    assert route.output_schema == Contract.output_schema()
  end

  test "does not let a legacy route output contract bypass route validation" do
    workflow = create_workflow()
    route_config = route_config()

    assert {:error, changeset} =
             WorkflowSteps.insert(
               workflow,
               Map.merge(@valid_attrs, %{
                 step_type: "route",
                 prompt: nil,
                 route_config: route_config,
                 output_schema: Contract.output_schema()
               })
             )

    assert %{route_config: [message]} = errors_on(changeset)
    assert message =~ "$.predecessors"
  end

  test "requires explicit route_config clearing before changing to a non-route step" do
    workflow = create_workflow()

    {:ok, step} =
      WorkflowSteps.insert(
        workflow,
        Map.merge(@valid_attrs, %{step_type: "route"})
      )

    assert {:error, changeset} =
             WorkflowSteps.update(step, %{step_type: "evaluate", route_config: route_config()})

    assert %{route_config: ["is only supported for route steps"]} = errors_on(changeset)

    assert {:ok, updated} =
             WorkflowSteps.update(step, %{step_type: "evaluate", route_config: nil})

    assert updated.step_type == :evaluate
    assert updated.route_config == nil
  end

  defp create_workflow do
    {:ok, user} = Users.insert(@valid_user_attrs)
    {:ok, project} = Projects.insert(user, %{name: "Routing Project"})
    {:ok, workflow} = Workflows.insert(project, %{name: "Routing Workflow"})
    workflow
  end

  defp route_config do
    %{
      "version" => 1,
      "match_policy" => "exactly_one",
      "rules" => [
        %{
          "id" => "high_priority",
          "when" => %{"ref" => "task.tags", "op" => "contains", "value" => "priority"},
          "transition" => %{"type" => "intra_workflow", "step_id" => Ecto.UUID.generate()}
        }
      ],
      "default" => %{
        "transition" => %{"type" => "inter_workflow", "workflow_id" => Ecto.UUID.generate()}
      }
    }
  end
end
