defmodule Sacrum.ProjectDataTest do
  use ExUnit.Case, async: true

  alias Sacrum.{Export, Import}
  alias Sacrum.Repo.Schemas.WorkflowStep

  test "round-trips route configuration and execution audit JSON" do
    route_config = route_config()

    route_step = %WorkflowStep{
      id: Ecto.UUID.generate(),
      name: "Route",
      goal: "Choose the next step",
      agents: ["router"],
      skills: ["routing"],
      agent_config: %{"provider" => "internal", "options" => %{"temperature" => 0}},
      step_order: 2,
      step_type: :route,
      prompt: "Fallback route prompt",
      output_schema: nil,
      persistence_options: nil,
      route_config: route_config,
      verbose_daemon_logging: false,
      workflow_id: Ecto.UUID.generate(),
      project_id: Ecto.UUID.generate(),
      inserted_at: ~U[2026-08-30 10:00:00.123456Z],
      updated_at: ~U[2026-08-30 10:01:00.123456Z]
    }

    route_context = %{
      "route" => %{
        "mode" => "deterministic",
        "source_execution_id" => Ecto.UUID.generate(),
        "config_version" => 1,
        "matched_rule_id" => "approved",
        "used_default" => false,
        "context" => %{
          "previous_output" => %{
            "route" => %{"result" => "approved", "handoff" => %{"review" => "needed"}}
          },
          "task" => %{"level" => "ticket", "tags" => ["priority", "customer-facing"]},
          "execution" => %{"step_visit_count" => 2}
        }
      }
    }

    transition_result =
      Jason.encode!(%{
        "dest_id" => Ecto.UUID.generate(),
        "transition_type" => "intra_workflow"
      })

    execution = %{
      id: Ecto.UUID.generate(),
      task_id: Ecto.UUID.generate(),
      task_run_id: Ecto.UUID.generate(),
      workflow_id: route_step.workflow_id,
      step_id: route_step.id,
      project_id: route_step.project_id,
      step_name: route_step.name,
      step_type: :route,
      status: "completed",
      context: route_context,
      prompt: route_step.prompt,
      output: "ordinary output; not route audit",
      transition_result: transition_result,
      model: "test-model",
      model_provider: "test-provider",
      input_tokens: 10,
      output_tokens: 20,
      cost: "0.123",
      duration_ms: 42,
      handoff: %{"review" => "needed", "priority" => 2},
      session_input_tokens: 1,
      session_cache_read_input_tokens: 2,
      session_output_tokens: 3,
      session_total_tokens: 4,
      context_window_input_tokens: 5,
      context_window_cache_read_input_tokens: 6,
      context_window_total_tokens: 7,
      inserted_at: ~U[2026-08-30 10:02:00.123456Z],
      updated_at: ~U[2026-08-30 10:03:00.123456Z]
    }

    assert {:ok, json} =
             Export.encode(%{workflow_steps: [route_step], step_executions: [execution]})

    assert {:ok, imported} = Import.load(json)

    [imported_step] = imported.workflow_steps
    [imported_execution] = imported.step_executions

    assert imported_step[:route_config] == route_config
    assert imported_step[:prompt] == route_step.prompt
    assert imported_step[:step_type] == "route"
    assert imported_execution[:context] == route_context
    assert imported_execution[:transition_result] == transition_result
    assert imported_execution[:handoff] == execution.handoff
    assert imported_execution[:output] == execution.output
  end

  test "keeps prompt-only route steps as fallback data without synthesizing route_config" do
    document = %{
      "version" => 1,
      "workflow_steps" => [
        %{
          "name" => "Prompt route",
          "step_type" => "route",
          "prompt" => "Choose the next step from the model"
        }
      ],
      "step_executions" => []
    }

    assert {:ok, %{workflow_steps: [step]}} = Import.load(document)
    assert step[:prompt] == "Choose the next step from the model"
    refute Map.has_key?(step, :route_config)
  end

  test "rejects invalid route_config through the WorkflowStep changeset without prompt fallback" do
    record = %{
      "name" => "Invalid route",
      "step_type" => "route",
      "prompt" => "This must not make the invalid program acceptable",
      "route_config" => %{
        "version" => 1,
        "match_policy" => "exactly_one",
        "rules" => [
          %{
            "id" => "bad",
            "when" => %{"ref" => "task.unknown", "op" => "eq", "value" => "x"},
            "transition" => %{"type" => "intra_workflow", "step_id" => Ecto.UUID.generate()}
          }
        ]
      }
    }

    assert {:error, {"workflow_steps", 0, changeset}} =
             Import.load(%{"version" => 1, "workflow_steps" => [record], "step_executions" => []})

    assert [route_config: {message, []}] = changeset.errors
    assert message == "$.rules[0].when.ref: is not a supported route reference"
  end

  test "rejects a route with neither deterministic configuration nor prompt" do
    assert {:error, {"workflow_steps", 0, changeset}} =
             Import.load(%{
               "version" => 1,
               "workflow_steps" => [%{"name" => "Unconfigured route", "step_type" => "route"}],
               "step_executions" => []
             })

    assert [prompt: {message, []}] = changeset.errors
    assert message == "route steps require route_config or a non-null prompt"
  end

  defp route_config do
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
          "transition" => %{
            "type" => "intra_workflow",
            "step_id" => Ecto.UUID.generate()
          }
        }
      ]
    }
  end
end
