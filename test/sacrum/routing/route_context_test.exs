defmodule Sacrum.Routing.RouteContextTest do
  use ExUnit.Case, async: true

  alias Sacrum.Routing.RouteContext

  test "builds only the four whitelisted route values" do
    previous_output = %{"route" => %{"result" => "approved", "handoff" => %{"note" => "ready"}}}
    task = %{"level" => "ticket", "tags" => ["backend", "urgent"]}

    assert {:ok, context} = RouteContext.build(previous_output, task, 2)
    assert {:ok, "approved"} = RouteContext.fetch(context, :previous_output_route_result)
    assert {:ok, "ticket"} = RouteContext.fetch(context, :task_level)
    assert {:ok, ["backend", "urgent"]} = RouteContext.fetch(context, :task_tags)
    assert {:ok, 2} = RouteContext.fetch(context, :execution_step_visit_count)

    assert {:error, %{code: :route_reference_unknown}} = RouteContext.fetch(context, :task_title)

    assert RouteContext.interpolation_context(context) == %{
             "previous_output" => %{
               "route" => %{"result" => "approved", "handoff" => %{"note" => "ready"}}
             },
             "task" => %{"level" => "ticket", "tags" => ["backend", "urgent"]},
             "execution" => %{"step_visit_count" => 2}
           }

    assert RouteContext.allowed_interpolation_path?("previous_output.route.result")
    assert RouteContext.allowed_interpolation_path?("previous_output.route.handoff.note")
    refute RouteContext.allowed_interpolation_path?("task.title")
    refute RouteContext.allowed_interpolation_path?("previous_output.route")
  end

  test "structured references return :missing for absent, null, or non-object paths" do
    output = %{
      "approved" => %{"type" => "choice", "choice" => "no", "confidence" => 0.4, "legend" => nil},
      "urgent" => %{"type" => "noul", "noul" => 0.2, "probabilities" => "unexpected"}
    }

    task = %{"level" => "ticket", "tags" => []}

    assert {:ok, context} = RouteContext.build_structured(output, task, 1)
    assert {:ok, "no"} = RouteContext.fetch(context, "previous_output.approved.choice")
    assert {:ok, 0.4} = RouteContext.fetch(context, "previous_output.approved.confidence")
    assert :missing = RouteContext.fetch(context, "previous_output.approved.legend")
    assert :missing = RouteContext.fetch(context, "previous_output.absent.choice")
    assert :missing = RouteContext.fetch(context, "previous_output.urgent.probabilities.yes")

    assert {:error, %{code: :route_reference_unknown}} =
             RouteContext.fetch(context, "task.title")

    assert RouteContext.interpolation_context(context)["previous_output"] == %{}
  end

  test "rejects malformed predecessor output and invalid task values" do
    assert {:error, %{code: :route_input_invalid, path: "$.previous_output.route"}} =
             RouteContext.build(%{"route" => %{}}, %{"level" => "task", "tags" => []}, 1)

    assert {:error, %{path: "$.task.level"}} =
             RouteContext.build(valid_output(), %{"level" => "high", "tags" => []}, 1)

    assert {:error, %{path: "$.task.tags"}} =
             RouteContext.build(valid_output(), %{"level" => "task", "tags" => [1]}, 1)

    assert {:error, %{path: "$.execution.step_visit_count"}} =
             RouteContext.build(valid_output(), %{"level" => "task", "tags" => []}, 0)

    assert {:error, %{path: "$.task"}} =
             RouteContext.build(valid_output(), %{level: "task", tags: []}, 1)
  end

  defp valid_output do
    %{"route" => %{"result" => "approved", "handoff" => %{"note" => "ready"}}}
  end
end
