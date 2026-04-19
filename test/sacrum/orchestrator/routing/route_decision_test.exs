defmodule Sacrum.Orchestrator.Routing.RouteDecisionTest do
  use Sacrum.DataCase

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.Routing.RouteDecision
  alias Sacrum.Repo

  # ===== Setup helpers =====

  defp create_user do
    {:ok, user} =
      Repo.Users.insert(%{
        email: "route_decision_test@example.com",
        username: "route_decision_test",
        password: "password123"
      })

    user
  end

  defp create_project(user) do
    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "RD Test Project"})
    project
  end

  defp create_workflow(user, project) do
    {:ok, workflow} =
      Accounts.Workflows.insert(user.id, project.id, %{
        name: "Test Workflow",
        auto_advance: false
      })

    workflow
  end

  defp create_step(user, workflow, attrs) do
    default_attrs = %{
      "name" => "Test Step",
      "step_order" => 1,
      "is_final" => false,
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

  defp create_step_execution(user, task, workflow, step_name, attrs \\ %{}) do
    default_attrs = %{
      "task_id" => task.id,
      "project_id" => task.project_id,
      "workflow_id" => workflow.id,
      "step_name" => step_name,
      "status" => "completed"
    }

    {:ok, execution} =
      Accounts.StepExecutions.insert(user.id, Map.merge(default_attrs, attrs))

    execution
  end

  # ===== Tests =====

  describe "parse_route_output/1" do
    test "returns ok with decoded map when output is valid JSON" do
      output =
        Jason.encode!(%{"transition_to" => "step_2", "transition_type" => "intra_workflow"})

      result = RouteDecision.parse_route_output(output)

      assert {:ok, decoded} = result
      assert decoded["transition_to"] == "step_2"
      assert decoded["transition_type"] == "intra_workflow"
    end

    test "returns error when output is nil" do
      result = RouteDecision.parse_route_output(nil)

      assert result == {:error, :missing_route_output}
    end

    test "returns error when output is invalid JSON" do
      result = RouteDecision.parse_route_output("{invalid json")

      assert result == {:error, :invalid_json_output}
    end

    test "handles JSON-encoded strings with nested structures" do
      output =
        Jason.encode!(%{
          "transition_to" => "dest_id",
          "transition_type" => "inter_workflow",
          "handoff" => %{"key" => "value"}
        })

      result = RouteDecision.parse_route_output(output)

      assert {:ok, decoded} = result
      assert decoded["handoff"] == %{"key" => "value"}
    end
  end

  describe "extract_routing_data/1" do
    test "returns ok with routing data when decoded is valid" do
      decoded = %{
        "transition_to" => "dest_step_id",
        "transition_type" => "intra_workflow"
      }

      result = RouteDecision.extract_routing_data(decoded)

      assert {:ok, routing_data} = result
      assert routing_data.dest_id == "dest_step_id"
      assert routing_data.transition_type == "intra_workflow"
    end

    test "includes handoff when present" do
      decoded = %{
        "transition_to" => "dest_id",
        "transition_type" => "inter_workflow",
        "handoff" => %{"key" => "value"}
      }

      result = RouteDecision.extract_routing_data(decoded)

      assert {:ok, routing_data} = result
      assert routing_data.handoff == %{"key" => "value"}
    end

    test "allows nil handoff" do
      decoded = %{
        "transition_to" => "dest_id",
        "transition_type" => "intra_workflow",
        "handoff" => nil
      }

      result = RouteDecision.extract_routing_data(decoded)

      assert {:ok, routing_data} = result
      assert routing_data.handoff == nil
    end

    test "returns error when transition_to is missing" do
      decoded = %{"transition_type" => "intra_workflow"}

      result = RouteDecision.extract_routing_data(decoded)

      assert result == {:error, :invalid_route_output_format}
    end

    test "returns error when transition_type is missing" do
      decoded = %{"transition_to" => "dest_id"}

      result = RouteDecision.extract_routing_data(decoded)

      assert result == {:error, :invalid_route_output_format}
    end

    test "returns error when transition_type is invalid" do
      decoded = %{
        "transition_to" => "dest_id",
        "transition_type" => "invalid_type"
      }

      result = RouteDecision.extract_routing_data(decoded)

      assert result == {:error, :invalid_route_output_format}
    end

    test "returns error when decoded is not a map" do
      result = RouteDecision.extract_routing_data("not a map")

      assert result == {:error, :route_output_not_map}
    end

    test "returns error when decoded is a list" do
      result = RouteDecision.extract_routing_data([])

      assert result == {:error, :route_output_not_map}
    end
  end

  describe "persist_route_decision/3" do
    test "updates step execution with transition_result" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step = create_step(user, workflow, %{})
      task = create_task(user, project, workflow)

      execution = create_step_execution(user, task, workflow, step.name)

      result = RouteDecision.persist_route_decision(execution, "dest_id", "intra_workflow")

      assert result == :ok

      # Verify the persisted data
      updated_execution = Repo.get(Sacrum.Repo.Schemas.StepExecution, execution.id)
      assert updated_execution.transition_result != nil

      decoded = Jason.decode!(updated_execution.transition_result)
      assert decoded["dest_id"] == "dest_id"
      assert decoded["transition_type"] == "intra_workflow"
    end
  end

  describe "log_route_decision/5" do
    test "logs routing decision without crashing" do
      result =
        RouteDecision.log_route_decision(
          "task_id",
          "execution_id",
          "dest_id",
          "intra_workflow",
          %{
            "key" => "value"
          }
        )

      assert result == :ok
    end

    test "logs routing decision with non-map handoff" do
      result =
        RouteDecision.log_route_decision(
          "task_id",
          "execution_id",
          "dest_id",
          "inter_workflow",
          nil
        )

      assert result == :ok
    end

    test "logs routing decision with empty handoff" do
      result =
        RouteDecision.log_route_decision(
          "task_id",
          "execution_id",
          "dest_id",
          "intra_workflow",
          %{}
        )

      assert result == :ok
    end
  end
end
