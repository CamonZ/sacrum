defmodule Sacrum.Orchestrator.WorkflowGraphTest do
  use Sacrum.DataCase

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.WorkflowGraph
  alias Sacrum.Repo

  # ===== Setup helpers =====

  defp create_user do
    unique_suffix = :erlang.unique_integer([:positive])

    {:ok, user} =
      Repo.Users.insert(%{
        email: "workflow_graph_test_#{unique_suffix}@example.com",
        username: "workflow_graph_test_#{unique_suffix}",
        password: "password123"
      })

    user
  end

  defp create_project(user) do
    unique_suffix = :erlang.unique_integer([:positive])

    {:ok, project} =
      Accounts.Projects.insert(user.id, %{name: "WG Test Project #{unique_suffix}"})

    project
  end

  defp create_workflow(user, project) do
    {:ok, workflow} =
      Accounts.Workflows.insert(user.id, project.id, %{
        name: "Test Workflow"
      })

    workflow
  end

  defp create_step(user, workflow, attrs) do
    default_attrs = %{
      "name" => "Test Step",
      "step_order" => 1,
      "agents" => ["test"],
      "skills" => ["test_skill"],
      "agent_config" => %{"model" => "test-model"},
      "workflow_id" => workflow.id,
      "project_id" => workflow.project_id,
      "prompt" => "default prompt"
    }

    {:ok, step} = Accounts.WorkflowSteps.insert(user.id, Map.merge(default_attrs, attrs))
    step
  end

  defp create_transition(user, from_step, to_step) do
    {:ok, transition} =
      Accounts.StepTransitions.insert(user.id, %{
        "from_step_id" => from_step.id,
        "to_step_id" => to_step.id,
        "project_id" => from_step.project_id,
        "label" => "next"
      })

    transition
  end

  defp create_task(user, project, workflow) do
    {:ok, task} =
      Accounts.Tasks.insert(user.id, project.id, %{
        title: "Test Task",
        description: "A test task description",
        level: "ticket",
        tags: ["test"]
      })

    {:ok, task} = Repo.TaskWorkflows.assign_workflow(task, workflow)
    task
  end

  # ===== Tests =====

  describe "load_validated_workflow_and_graph/2" do
    test "returns ok with workflow and step/transition maps on success" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step1 = create_step(user, workflow, %{"name" => "step_1", "step_order" => 1})
      step2 = create_step(user, workflow, %{"name" => "step_2", "step_order" => 2})
      create_transition(user, step1, step2)
      {:ok, workflow} = Accounts.Workflows.update(workflow, %{initial_step_id: step1.id})

      task = create_task(user, project, workflow)

      {:ok, loaded_workflow, steps, transitions} =
        WorkflowGraph.load_validated_workflow_and_graph(user.id, task)

      assert loaded_workflow.id == workflow.id
      assert Map.has_key?(steps, step1.id)
      assert Map.has_key?(steps, step2.id)
      assert Map.has_key?(transitions, step1.id)
      assert transitions[step1.id] == [step2.id]
      assert transitions[step2.id] == []
    end

    test "rejects a workflow whose configured route no longer matches the graph" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)

      source =
        create_step(user, workflow, %{
          "name" => "source",
          "output_schema" => predecessor_schema(["approved"])
        })

      route =
        create_step(user, workflow, %{
          "name" => "route",
          "step_order" => 2,
          "step_type" => "route"
        })

      destination =
        create_step(user, workflow, %{
          "name" => "destination",
          "step_order" => 3
        })

      create_transition(user, source, route)
      route_transition = create_transition(user, route, destination)

      # Persist a valid configuration, then break the graph behind the
      # guarded write API: the route's only outgoing edge disappears, so its
      # configured target is illegal.
      {:ok, _route} =
        Repo.update(
          Ecto.Changeset.change(route, %{
            route_config: %{
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
                  "transition" => %{
                    "type" => "intra_workflow",
                    "step_id" => destination.id
                  }
                }
              ],
              "default" => %{
                "transition" => %{"type" => "intra_workflow", "step_id" => destination.id}
              }
            }
          })
        )

      Repo.delete(route_transition)

      task = create_task(user, project, workflow)

      assert {:error, %{code: :route_target_invalid}} =
               WorkflowGraph.load_validated_workflow_and_graph(user.id, task)
    end
  end

  describe "get_current_step/1" do
    test "returns error when current step not found in cache" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step = create_step(user, workflow, %{})
      {:ok, workflow} = Accounts.Workflows.update(workflow, %{initial_step_id: step.id})
      task = create_task(user, project, workflow)

      # Create another step but don't include it in the steps cache
      other_step = create_step(user, workflow, %{"name" => "other_step", "step_order" => 2})

      # Manually set current_step_id to the other step
      {:ok, task_with_step} =
        Repo.update(Ecto.Changeset.change(task, %{current_step_id: other_step.id}))

      # But don't include other_step in the steps cache
      data = %{task: task_with_step, steps: %{step.id => step}}

      result = WorkflowGraph.get_current_step(data)
      assert result == {:error, :step_not_found}
    end

    test "returns ok with the current step from cache" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step = create_step(user, workflow, %{})
      task = create_task(user, project, workflow)

      # Manually set current_step_id
      {:ok, task_with_step} =
        Repo.update(Ecto.Changeset.change(task, %{current_step_id: step.id}))

      data = %{task: task_with_step, steps: %{step.id => step}}

      {:ok, returned_step} = WorkflowGraph.get_current_step(data)
      assert returned_step.id == step.id
    end
  end

  describe "RouteValidation.load_snapshot/1" do
    test "keeps every incoming edge identity and unions its result domains" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)

      approved =
        create_step(user, workflow, %{
          "name" => "approved",
          "output_schema" => predecessor_schema(["approved"])
        })

      rejected =
        create_step(user, workflow, %{
          "name" => "rejected",
          "step_order" => 2,
          "output_schema" => predecessor_schema(["rejected", "retry"])
        })

      route =
        create_step(user, workflow, %{
          "name" => "route",
          "step_order" => 3,
          "step_type" => "route"
        })

      approved_transition = create_transition(user, approved, route)
      rejected_transition = create_transition(user, rejected, route)

      assert {:ok, snapshot} = Sacrum.Repo.RouteValidation.load_snapshot(workflow.id)

      predecessors = Sacrum.Routing.RouteValidator.predecessor_schemas(route, snapshot)

      assert Enum.map(predecessors, & &1.transition_id) |> Enum.sort() ==
               Enum.sort([approved_transition.id, rejected_transition.id])

      schemas = Enum.map(predecessors, & &1.output_schema)

      {:ok, %{result_values: result_values}} =
        Sacrum.Routing.RoutePredecessors.derive_type_environment(schemas)

      assert result_values == MapSet.new(["approved", "rejected", "retry"])
    end

    test "returns an error for an unknown workflow" do
      assert {:error, :workflow_not_found} =
               Sacrum.Repo.RouteValidation.load_snapshot(Ecto.UUID.generate())
    end
  end

  describe "get_outgoing_transitions/2" do
    test "returns empty list when no transitions exist" do
      data = %{transitions: %{"step_1" => []}}
      result = WorkflowGraph.get_outgoing_transitions(data, "step_1")
      assert result == []
    end

    test "returns list of destination step IDs for multi-transition" do
      data = %{transitions: %{"step_1" => ["step_2", "step_3"]}}
      result = WorkflowGraph.get_outgoing_transitions(data, "step_1")
      assert result == ["step_2", "step_3"]
    end

    test "returns empty list when step has no transitions key" do
      data = %{transitions: %{"step_1" => ["step_2"]}}
      result = WorkflowGraph.get_outgoing_transitions(data, "nonexistent")
      assert result == []
    end
  end

  describe "select_single_transition/1" do
    test "returns ok with the single destination" do
      result = WorkflowGraph.select_single_transition(["step_2"])
      assert result == {:ok, "step_2"}
    end

    test "returns error when no outgoing transitions" do
      result = WorkflowGraph.select_single_transition([])
      assert result == {:error, :no_outgoing_transitions}
    end

    test "returns error when multiple outgoing transitions" do
      result = WorkflowGraph.select_single_transition(["step_2", "step_3"])
      assert result == {:error, :multiple_outgoing_transitions}
    end
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
              "required" => ["note"],
              "properties" => %{"note" => %{"type" => "string"}}
            }
          }
        }
      },
      "required" => ["route"],
      "additionalProperties" => false
    }
  end
end
