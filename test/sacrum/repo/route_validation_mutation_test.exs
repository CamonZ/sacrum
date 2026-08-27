defmodule Sacrum.Repo.RouteValidationMutationTest do
  use Sacrum.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Sacrum.Accounts
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{Project, StepTransition, User, Workflow, WorkflowStep}

  test "rejects source-contract, transition, and destination mutations that invalidate a route" do
    %{
      destination: destination,
      route: route,
      source: source,
      source_transition: source_transition,
      source_workflow: source_workflow
    } =
      configured_intra_route()

    invalid_predecessor = create_step(source_workflow, "invalid predecessor", 4)

    assert {:error, changeset} =
             Accounts.StepTransitions.insert(invalid_predecessor.user_id, %{
               from_step_id: invalid_predecessor.id,
               to_step_id: route.id,
               project_id: route.project_id
             })

    assert %{route_config: [message]} = errors_on(changeset)
    assert message =~ "$.predecessors"

    refute Repo.exists?(
             from(transition in StepTransition,
               where:
                 transition.from_step_id == ^invalid_predecessor.id and
                   transition.to_step_id == ^route.id
             )
           )

    assert {:error, changeset} = Accounts.WorkflowSteps.update(source, %{output_schema: nil})
    assert %{route_config: [message]} = errors_on(changeset)
    assert message =~ "$.predecessors[#{source_transition.id}]"

    assert Repo.get!(WorkflowStep, source.id).output_schema == source.output_schema

    assert {:error, changeset} = Accounts.StepTransitions.delete(source_transition)
    assert %{route_config: [message]} = errors_on(changeset)
    assert message =~ "$.predecessors"
    assert Repo.get!(StepTransition, source_transition.id).id == source_transition.id

    assert {:error, changeset} = Accounts.WorkflowSteps.delete(destination)
    assert %{route_config: [message]} = errors_on(changeset)
    assert message =~ "$.rules[0].transition.step_id"
    assert Repo.get!(WorkflowStep, destination.id).id == destination.id
    assert Repo.get!(WorkflowStep, route.id).route_config == route.route_config
  end

  test "revalidates workflow transition targets, syncs, initial steps, and workflow deletion" do
    %{
      destination: destination,
      destination_workflow: destination_workflow,
      route: route,
      source_workflow: source_workflow,
      workflow_transition: workflow_transition
    } = configured_inter_route()

    invalid_entry = create_step(source_workflow, "invalid-entry", 3)

    assert {:error, changeset} =
             Repo.WorkflowTransitions.update(
               Ecto.Changeset.change(workflow_transition, %{target_step_id: invalid_entry.id})
             )

    assert %{route_config: [message]} = errors_on(changeset)
    assert message =~ "$.rules[0].transition.workflow_id"

    assert Repo.get!(Sacrum.Repo.Schemas.WorkflowTransition, workflow_transition.id).target_step_id ==
             nil

    assert {:error, changeset} =
             Accounts.Workflows.sync_transitions(source_workflow, [
               %{
                 "to_workflow_id" => destination_workflow.id,
                 "target_step_id" => invalid_entry.id
               }
             ])

    assert %{route_config: [message]} = errors_on(changeset)
    assert message =~ "$.rules[0].transition.workflow_id"

    assert Repo.get!(Sacrum.Repo.Schemas.WorkflowTransition, workflow_transition.id).target_step_id ==
             nil

    assert {:error, changeset} =
             Accounts.Workflows.update(destination_workflow, %{initial_step_id: invalid_entry.id})

    assert %{route_config: [message]} = errors_on(changeset)
    assert message =~ "$.rules[0].transition.workflow_id"
    assert Repo.get!(Workflow, destination_workflow.id).initial_step_id == destination.id

    assert {:error, changeset} = Accounts.Workflows.delete(destination_workflow)
    assert %{route_config: [message]} = errors_on(changeset)
    assert message =~ "$.rules[0].transition.workflow_id"
    assert Repo.get!(Workflow, destination_workflow.id).id == destination_workflow.id
    assert Repo.get!(WorkflowStep, route.id).route_config == route.route_config
  end

  test "concurrent route configuration and predecessor deletion cannot commit an invalid graph" do
    {project_id, user_id, route_id, source_transition_id} =
      committed_db(fn ->
        %{
          project: project,
          route: route,
          source_transition: transition,
          user: user
        } =
          unconfigured_intra_route()

        {project.id, user.id, route.id, transition.id}
      end)

    try do
      parent = self()

      configure_task =
        Task.async(fn ->
          committed_db(fn ->
            send(parent, :configure_ready)

            receive do
              :go ->
                route = Repo.get!(WorkflowStep, route_id)
                destination = destination_for(route)

                Accounts.WorkflowSteps.update(route, %{
                  route_config: intra_route_config(destination.id)
                })
            end
          end)
        end)

      delete_task =
        Task.async(fn ->
          committed_db(fn ->
            send(parent, :delete_ready)

            receive do
              :go ->
                transition = Repo.get!(StepTransition, source_transition_id)
                Accounts.StepTransitions.delete(transition)
            end
          end)
        end)

      assert_receive :configure_ready
      assert_receive :delete_ready
      send(configure_task.pid, :go)
      send(delete_task.pid, :go)

      results = [Task.await(configure_task, 10_000), Task.await(delete_task, 10_000)]

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, %Ecto.Changeset{}}, &1)) == 1

      {configured?, predecessor_exists?} =
        committed_db(fn ->
          route = Repo.get!(WorkflowStep, route_id)

          {not is_nil(route.route_config),
           not is_nil(Repo.get(StepTransition, source_transition_id))}
        end)

      refute configured? and not predecessor_exists?
    after
      cleanup_committed_project(project_id, user_id)
    end
  end

  defp configured_intra_route do
    route_data = unconfigured_intra_route()

    {:ok, route} =
      Accounts.WorkflowSteps.update(route_data.route, %{
        route_config: intra_route_config(route_data.destination.id)
      })

    %{route_data | route: route}
  end

  defp unconfigured_intra_route do
    user = create_user()
    project = create_project(user)
    workflow = create_workflow(user, project, "Intra route")
    source = create_step(workflow, "source", 1, output_schema: predecessor_schema(["approved"]))
    destination = create_step(workflow, "destination", 2)
    route = create_step(workflow, "route", 3, step_type: "route", prompt: "Legacy fallback")
    source_transition = create_step_transition(source, route)
    create_step_transition(route, destination)

    %{
      destination: destination,
      project: project,
      route: route,
      source: source,
      source_transition: source_transition,
      source_workflow: workflow,
      user: user
    }
  end

  defp configured_inter_route do
    user = create_user()
    project = create_project(user)
    source_workflow = create_workflow(user, project, "Source")
    destination_workflow = create_workflow(user, project, "Destination")

    source =
      create_step(source_workflow, "source", 1, output_schema: predecessor_schema(["approved"]))

    route = create_step(source_workflow, "route", 2, step_type: "route")
    destination = create_step(destination_workflow, "destination", 1)
    create_step_transition(source, route)

    {:ok, destination_workflow} =
      Accounts.Workflows.update(destination_workflow, %{initial_step_id: destination.id})

    workflow_transition = create_workflow_transition(source_workflow, destination_workflow)

    {:ok, route} =
      Accounts.WorkflowSteps.update(route, %{
        route_config: inter_route_config(destination_workflow.id)
      })

    %{
      destination: destination,
      destination_workflow: destination_workflow,
      route: route,
      source_workflow: source_workflow,
      workflow_transition: workflow_transition
    }
  end

  defp create_user do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Repo.Users.insert(%{
        email: "route_mutation_#{suffix}@example.com",
        username: "route_mutation_#{suffix}",
        password: "password123"
      })

    user
  end

  defp create_project(user) do
    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Route mutation"})
    project
  end

  defp create_workflow(user, project, name) do
    {:ok, workflow} = Accounts.Workflows.insert(user.id, project.id, %{name: name})
    workflow
  end

  defp create_step(workflow, name, order, attrs \\ []) do
    defaults = %{
      name: name,
      prompt: "Prompt for #{name}",
      step_order: order,
      workflow_id: workflow.id,
      project_id: workflow.project_id
    }

    {:ok, step} =
      Accounts.WorkflowSteps.insert(workflow.user_id, Map.merge(defaults, Map.new(attrs)))

    step
  end

  defp create_step_transition(from_step, to_step) do
    {:ok, transition} =
      Accounts.StepTransitions.insert(from_step.user_id, %{
        from_step_id: from_step.id,
        to_step_id: to_step.id,
        project_id: from_step.project_id
      })

    transition
  end

  defp create_workflow_transition(from_workflow, to_workflow) do
    {:ok, transition} =
      Accounts.WorkflowTransitions.insert(from_workflow.user_id, %{
        from_workflow_id: from_workflow.id,
        to_workflow_id: to_workflow.id,
        project_id: from_workflow.project_id
      })

    transition
  end

  defp destination_for(route) do
    Repo.one!(
      from(transition in StepTransition,
        join: destination in WorkflowStep,
        on: destination.id == transition.to_step_id,
        where: transition.from_step_id == ^route.id,
        select: destination
      )
    )
  end

  defp intra_route_config(destination_id) do
    route_config(%{"type" => "intra_workflow", "step_id" => destination_id})
  end

  defp inter_route_config(workflow_id) do
    route_config(%{"type" => "inter_workflow", "workflow_id" => workflow_id})
  end

  defp route_config(target) do
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
          "transition" => target
        }
      ],
      "default" => %{"transition" => target}
    }
  end

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

  defp committed_db(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp cleanup_committed_project(project_id, user_id) do
    committed_db(fn ->
      Repo.delete_all(from(project in Project, where: project.id == ^project_id))
      Repo.delete_all(from(user in User, where: user.id == ^user_id))
    end)
  end
end
