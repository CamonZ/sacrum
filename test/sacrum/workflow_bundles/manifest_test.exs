defmodule Sacrum.WorkflowBundles.ManifestTest do
  use ExUnit.Case, async: true

  alias Sacrum.WorkflowBundles.Manifest

  describe "validate/1" do
    test "normalizes a V1 graph and validates route targets against source edges" do
      assert {:ok, bundle} = Manifest.validate(valid_bundle())

      assert [%{workflow_ref: "build", initial_step: %{step_ref: "start"}}] = bundle.workflows

      assert [
               %{from: %{step_ref: "start"}, to: %{step_ref: "route"}},
               %{from: %{step_ref: "route"}, to: %{step_ref: "finish"}}
             ] = bundle.step_edges
    end

    test "rejects unknown structural fields and duplicate references" do
      assert {:error, %{path: "workflows[0].unexpected"}} =
               Manifest.validate(
                 put_in(valid_bundle(), ["workflows", Access.at(0), "unexpected"], true)
               )

      duplicate =
        update_in(valid_bundle(), ["workflows"], fn workflows ->
          workflows ++ [Map.put(hd(workflows), "name", "Second")]
        end)

      assert {:error, %{path: "workflows[1].workflow_ref"}} = Manifest.validate(duplicate)
    end

    test "rejects invalid finish edges and unresolved route targets" do
      invalid_finish =
        update_in(valid_bundle(), ["step_edges"], fn edges ->
          edges ++ [step_edge("finish", "start")]
        end)

      assert {:error, %{path: "workflows[0].steps[2]", message: message}} =
               Manifest.validate(invalid_finish)

      assert message =~ "finish steps cannot have outgoing"

      invalid_route =
        put_in(
          valid_bundle(),
          [
            "workflows",
            Access.at(0),
            "steps",
            Access.at(1),
            "config",
            "route_config",
            "default",
            "transition",
            "step_ref"
          ],
          "start"
        )

      assert {:ok, normalized} = Manifest.validate(invalid_route)
      assert {:error, %{path: path, message: message}} = remap_with_generated_ids(normalized)
      assert path =~ "route_config"
      assert message == "must be an outgoing step edge"
    end

    test "enforces collection limits before normalizing the graph" do
      too_many_workflows =
        Map.put(valid_bundle(), "workflows", List.duplicate(hd(valid_bundle()["workflows"]), 101))

      assert {:error, %{path: "workflows", message: message}} =
               Manifest.validate(too_many_workflows)

      assert message =~ "at most 100 workflows"
    end

    test "returns a validation error instead of raising for malformed collections" do
      malformed = put_in(valid_bundle(), ["workflows", Access.at(0), "steps"], %{})

      assert {:error, %{path: "workflows[0].steps", message: "must be an array"}} =
               Manifest.validate(malformed)
    end
  end

  describe "step config" do
    test "keeps a structured inference config unchanged" do
      assert {:ok, bundle} = Manifest.validate(structured_bundle(structured_step()))

      assert [%{step_type: "structured_inference", config: config}] = hd(bundle.workflows).steps
      assert config == structured_config()
    end

    test "rejects fields the step type's config does not declare" do
      bundle =
        put_in(
          valid_bundle(),
          ["workflows", Access.at(0), "steps", Access.at(0), "config"],
          %{"questions" => questions()}
        )

      assert {:error,
              %{
                path: "workflows[0].steps[0].config.questions",
                message: "is not supported for llm_inference steps"
              }} = Manifest.validate(bundle)

      step = put_in(structured_step(), ["config", "prompt"], "Classify")

      assert {:error,
              %{
                path: "workflows[0].steps[0].config.prompt",
                message: "is not supported for structured_inference steps"
              }} = Manifest.validate(structured_bundle(step))
    end

    test "rejects a config on a step type without one" do
      bundle =
        put_in(
          valid_bundle(),
          ["workflows", Access.at(0), "steps", Access.at(2), "config"],
          %{"prompt" => "Done"}
        )

      assert {:error,
              %{path: "workflows[0].steps[2].config", message: "must be null for finish steps"}} =
               Manifest.validate(bundle)
    end

    test "rejects a structured inference config missing its provider" do
      {_provider, step} = pop_in(structured_step(), ["config", "provider"])

      assert {:error, %{path: "workflows[0].steps[0].config.provider", message: "is required"}} =
               Manifest.validate(structured_bundle(step))

      step = Map.delete(structured_step(), "config")

      assert {:error, %{path: "workflows[0].steps[0].config.provider", message: "is required"}} =
               Manifest.validate(structured_bundle(step))
    end

    test "rejects invalid questions at their question path" do
      step = put_in(structured_step(), ["config", "questions", "risky", "type"], "maybe")

      assert {:error,
              %{
                path: "workflows[0].steps[0].config.questions.risky.type",
                message: "must be one of noul, choice, score"
              }} = Manifest.validate(structured_bundle(step))

      step = put_in(structured_step(), ["config", "questions", "size", "criteria"], ["only one"])

      assert {:error,
              %{
                path: "workflows[0].steps[0].config.questions.size.criteria",
                message: "must be an array of 2 to 10 levels"
              }} = Manifest.validate(structured_bundle(step))
    end

    test "rejects an invalid output schema at its config path" do
      bundle =
        put_in(
          valid_bundle(),
          ["workflows", Access.at(0), "steps", Access.at(0), "config"],
          %{"output_schema" => %{"type" => 7}}
        )

      assert {:error,
              %{
                path: "workflows[0].steps[0].config.output_schema",
                message: "must be a valid JSON Schema"
              }} = Manifest.validate(bundle)
    end
  end

  describe "remap_routes/3" do
    test "remaps only documented route targets and preserves opaque JSON" do
      {:ok, bundle} = Manifest.validate(valid_bundle())
      workflow_id = Ecto.UUID.generate()
      start_id = Ecto.UUID.generate()
      route_id = Ecto.UUID.generate()
      finish_id = Ecto.UUID.generate()

      workflow_ids = %{"build" => workflow_id}

      step_ids = %{
        {"build", "start"} => start_id,
        {"build", "route"} => route_id,
        {"build", "finish"} => finish_id
      }

      assert {:ok, remapped} = Manifest.remap_routes(bundle, workflow_ids, step_ids)

      route_config =
        hd(remapped.workflows).steps |> Enum.at(1) |> get_in([:config, "route_config"])

      target = get_in(route_config, ["default", "transition"])

      assert target == %{"type" => "intra_workflow", "step_id" => finish_id}

      assert get_in(route_config, ["rules", Access.at(0), "handoff", "opaque_id"]) ==
               "00000000-0000-0000-0000-000000000099"
    end
  end

  defp valid_bundle do
    %{
      "workflows" => [
        %{
          "workflow_ref" => "build",
          "name" => "Build",
          "initial_step" => %{"workflow_ref" => "build", "step_ref" => "start"},
          "steps" => [
            %{"step_ref" => "start", "name" => "Start", "step_type" => "llm_inference"},
            %{
              "step_ref" => "route",
              "name" => "Route",
              "step_type" => "route",
              "config" => %{"route_config" => route_config()}
            },
            %{"step_ref" => "finish", "name" => "Finish", "step_type" => "finish"}
          ]
        }
      ],
      "step_edges" => [step_edge("start", "route"), step_edge("route", "finish")]
    }
  end

  defp structured_bundle(step) do
    %{
      "workflows" => [
        %{
          "workflow_ref" => "triage",
          "name" => "Triage",
          "steps" => [step]
        }
      ]
    }
  end

  defp structured_step do
    %{
      "step_ref" => "classify",
      "name" => "Classify",
      "step_type" => "structured_inference",
      "config" => structured_config()
    }
  end

  defp structured_config do
    %{
      "provider" => "typesafe",
      "model" => "system-one",
      "state" => %{"title" => "{{ task.title }}", "labels" => ["a", "b"]},
      "questions" => questions()
    }
  end

  defp questions do
    %{
      "risky" => %{"type" => "noul", "instructions" => "Is the change risky?"},
      "area" => %{
        "type" => "choice",
        "instructions" => "Which area does it touch?",
        "criteria" => %{"api" => "Server code", "ui" => nil}
      },
      "size" => %{
        "type" => "score",
        "instructions" => "How large is it?",
        "criteria" => ["small", "medium", "large"]
      }
    }
  end

  defp route_config do
    %{
      "version" => 1,
      "match_policy" => "exactly_one",
      "rules" => [
        %{
          "id" => "done",
          "when" => %{
            "ref" => "previous_output.route.result",
            "op" => "eq",
            "value" => "done"
          },
          "transition" => %{
            "type" => "intra_workflow",
            "step_ref" => "finish"
          },
          "handoff" => %{"opaque_id" => "00000000-0000-0000-0000-000000000099"}
        }
      ],
      "default" => %{
        "transition" => %{"type" => "intra_workflow", "step_ref" => "finish"}
      }
    }
  end

  defp step_edge(from, to) do
    %{
      "from" => %{"workflow_ref" => "build", "step_ref" => from},
      "to" => %{"workflow_ref" => "build", "step_ref" => to}
    }
  end

  defp remap_with_generated_ids(bundle) do
    workflow_ids = Map.new(bundle.workflows, &{&1.workflow_ref, Ecto.UUID.generate()})

    step_ids =
      for workflow <- bundle.workflows, step <- workflow.steps, into: %{} do
        {{workflow.workflow_ref, step.step_ref}, Ecto.UUID.generate()}
      end

    Manifest.remap_routes(bundle, workflow_ids, step_ids)
  end
end
