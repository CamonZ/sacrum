defmodule Sacrum.Orchestrator.Routing.RouteContextTest do
  use ExUnit.Case, async: true

  alias Sacrum.Orchestrator.Routing.RouteContext

  test "builds only the four whitelisted route values" do
    previous_output = %{"route" => %{"result" => "approved", "handoff" => %{"note" => "ready"}}}
    task = %{"level" => "ticket", "tags" => ["backend", "urgent"]}

    assert {:ok, context} = RouteContext.build(previous_output, task, 2)
    assert {:ok, "approved"} = RouteContext.fetch(context, :previous_output_route_result)
    assert {:ok, "ticket"} = RouteContext.fetch(context, :task_level)
    assert {:ok, ["backend", "urgent"]} = RouteContext.fetch(context, :task_tags)
    assert {:ok, 2} = RouteContext.fetch(context, :execution_step_visit_count)

    assert {:error, %{code: :route_reference_unknown}} = RouteContext.fetch(context, :task_title)
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
