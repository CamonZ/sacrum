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

  describe "load_workflow_and_graph/2" do
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
        WorkflowGraph.load_workflow_and_graph(user.id, task)

      assert loaded_workflow.id == workflow.id
      assert Map.has_key?(steps, step1.id)
      assert Map.has_key?(steps, step2.id)
      assert Map.has_key?(transitions, step1.id)
      assert transitions[step1.id] == [step2.id]
      assert transitions[step2.id] == []
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

  describe "validate_route_predecessors/1" do
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
          "step_type" => "route",
          "route_config" => route_config()
        })

      approved_transition = create_transition(user, approved, route)
      rejected_transition = create_transition(user, rejected, route)

      assert {:ok, %{predecessors: predecessors, type_environment: type_environment}} =
               WorkflowGraph.validate_route_predecessors(route)

      assert type_environment.result_values == MapSet.new(["approved", "rejected", "retry"])

      assert Enum.map(
               predecessors,
               &{&1.transition_id, &1.source_step_id, &1.destination_step_id}
             ) ==
               [
                 {approved_transition.id, approved.id, route.id},
                 {rejected_transition.id, rejected.id, route.id}
               ]
    end

    test "reports the source step and exact edge for an invalid predecessor contract" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      source = create_step(user, workflow, %{"output_schema" => nil})

      route =
        create_step(user, workflow, %{
          "name" => "route",
          "step_order" => 2,
          "step_type" => "route",
          "route_config" => route_config()
        })

      transition = create_transition(user, source, route)

      assert {:error,
              %{
                code: :route_input_invalid,
                transition_id: transition_id,
                source_step_id: source_step_id,
                destination_step_id: destination_step_id,
                path: path
              }} = WorkflowGraph.validate_route_predecessors(route)

      assert transition_id == transition.id
      assert source_step_id == source.id
      assert destination_step_id == route.id
      assert path == "$.predecessors[#{transition.id}]"
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

  defp route_config do
    %{
      "version" => 1,
      "match_policy" => "exactly_one",
      "rules" => [
        %{
          "id" => "ticket",
          "when" => %{"ref" => "task.level", "op" => "eq", "value" => "ticket"},
          "transition" => %{"type" => "intra_workflow", "step_id" => Ecto.UUID.generate()}
        }
      ]
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
