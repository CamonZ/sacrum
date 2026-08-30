defmodule Sacrum.Routing.HandoffTemplateTest do
  use ExUnit.Case, async: true

  alias Sacrum.Routing.{HandoffTemplate, RouteContext}

  test "renders nested structured values without coercing JSON types" do
    context = route_context()

    template = %{
      "summary" =>
        "result={{ previous_output.route.result }}, visit={{ execution.step_visit_count }}",
      "payload" => %{
        "object" => "{{ previous_output.route.handoff }}",
        "array" => "{{ previous_output.route.handoff.values }}",
        "number" => "{{ previous_output.route.handoff.count }}",
        "boolean" => "{{ previous_output.route.handoff.approved }}",
        "null" => "{{ previous_output.route.handoff.optional }}"
      },
      "constants" => [%{"active" => true}, 7, nil]
    }

    assert {:ok, rendered} = HandoffTemplate.render(template, context, "$.rules[0].handoff")

    assert rendered == %{
             "summary" => "result=approved, visit=2",
             "payload" => %{
               "object" => %{
                 "approved" => true,
                 "count" => 4,
                 "optional" => nil,
                 "values" => ["first", 2, false]
               },
               "array" => ["first", 2, false],
               "number" => 4,
               "boolean" => true,
               "null" => nil
             },
             "constants" => [%{"active" => true}, 7, nil]
           }
  end

  test "rejects malformed, non-object, and out-of-context templates" do
    assert {:error, %{code: :route_handoff_template_invalid, path: "$.rules[0].handoff"}} =
             HandoffTemplate.decode([], "$.rules[0].handoff")

    assert {:error,
            %{
              code: :route_handoff_template_invalid,
              path: "$.rules[0].handoff.note",
              message: message
            }} = HandoffTemplate.decode(%{"note" => "{{ task.level"}, "$.rules[0].handoff")

    assert message =~ "malformed interpolation"

    assert {:error,
            %{
              code: :route_handoff_template_invalid,
              path: "$.rules[0].handoff.note",
              message: message
            }} =
             HandoffTemplate.decode(%{"note" => "{{ task.title }}"}, "$.rules[0].handoff")

    assert message =~ "is not allowed"
  end

  test "fails explicitly when a valid nested handoff path is missing at runtime" do
    template = %{"note" => "{{ previous_output.route.handoff.missing }}"}

    assert {:error,
            %{
              code: :route_handoff_render_failed,
              path: "$.default.handoff.note",
              message: message
            }} = HandoffTemplate.render(template, route_context(), "$.default.handoff")

    assert message =~ "missing from the route-step context"
  end

  defp route_context do
    {:ok, context} =
      RouteContext.build(
        %{
          "route" => %{
            "result" => "approved",
            "handoff" => %{
              "approved" => true,
              "count" => 4,
              "optional" => nil,
              "values" => ["first", 2, false]
            }
          }
        },
        %{"level" => "ticket", "tags" => ["backend"]},
        2
      )

    context
  end
end
