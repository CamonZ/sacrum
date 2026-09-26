defmodule Sacrum.Repo.Schemas.WorkflowStepConfigTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.Schemas.WorkflowStep
  alias Sacrum.Repo.Schemas.WorkflowStep.Config

  @route_config %{
    "version" => 1,
    "match_policy" => "exactly_one",
    "rules" => [
      %{
        "id" => "tasks",
        "when" => %{"ref" => "task.level", "op" => "eq", "value" => "task"},
        "transition" => %{"type" => "intra_workflow", "step_id" => Ecto.UUID.generate()}
      }
    ]
  }

  defp create(attrs),
    do: WorkflowStep.create_changeset(%WorkflowStep{}, Map.put(attrs, :name, "Step"))

  describe "create" do
    test "casts the variant selected by step_type and fills its defaults" do
      changeset = create(%{step_type: "llm_inference", config: %{"prompt" => "Go"}})

      assert changeset.valid?

      assert get_field(changeset, :config) == %Config.LlmInference{
               version: 1,
               prompt: "Go",
               output_schema: nil,
               agents: [],
               skills: [],
               agent_config: %{}
             }

      assert get_field(create(%{step_type: "wait_children"}), :config) ==
               %Config.WaitChildren{version: 1, output_schema: nil}

      assert get_field(create(%{step_type: "route", config: %{}}), :config) ==
               %Config.Route{version: 1, route_config: nil}
    end

    test "rejects fields the variant does not declare" do
      cases = [
        {"llm_inference", %{"prompt" => "Go", "temperature" => 1}, "$.temperature"},
        {"llm_inference", %{"route_config" => @route_config}, "$.route_config"},
        {"wait_children", %{"prompt" => "Wait"}, "$.prompt"},
        {"route", %{"prompt" => "Pick"}, "$.prompt"}
      ]

      for {step_type, config, path} <- cases do
        assert %{config: [message]} = errors_on(create(%{step_type: step_type, config: config}))
        assert message == "#{path}: is not supported for #{step_type} steps"
      end
    end

    test "rejects any config on null-config steps" do
      for step_type <- ["human_input", "stop", "finish"], config <- [%{}, %{"version" => 1}] do
        changeset = create(%{step_type: step_type, config: config})
        assert %{config: ["must be null for #{step_type} steps"]} == errors_on(changeset)
      end

      assert %{config: nil} = apply_changes(create(%{step_type: "stop", config: nil}))
    end

    test "reports variant errors on the embedded field" do
      assert %{config: ["must be an object"]} =
               errors_on(create(%{step_type: "llm_inference", config: "prompt"}))

      assert %{config: %{version: ["only version 1 is supported"]}} =
               errors_on(create(%{step_type: "llm_inference", config: %{"version" => 2}}))

      assert %{config: %{agents: ["is invalid"]}} =
               errors_on(create(%{step_type: "llm_inference", config: %{"agents" => "x"}}))

      assert %{config: %{route_config: ["$.version: only version 1 is supported"]}} =
               errors_on(
                 create(%{
                   step_type: "route",
                   config: %{"route_config" => Map.put(@route_config, "version", 2)}
                 })
               )
    end
  end

  describe "update" do
    setup do
      step = %WorkflowStep{
        name: "Step",
        step_type: :llm_inference,
        config: %Config.LlmInference{prompt: "Old", agents: ["a"]}
      }

      %{step: step}
    end

    test "patches the fields it names", %{step: step} do
      changeset = WorkflowStep.update_changeset(step, %{config: %{"prompt" => "New"}})

      assert %Config.LlmInference{prompt: "New", agents: ["a"]} = get_field(changeset, :config)
    end

    test "keeps the config when none is given", %{step: step} do
      changeset = WorkflowStep.update_changeset(step, %{name: "Renamed"})

      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :config)
    end

    test "rejects changing the step type", %{step: step} do
      assert %{step_type: ["cannot be changed; create a new step instead"]} =
               errors_on(WorkflowStep.update_changeset(step, %{step_type: "wait_children"}))

      assert WorkflowStep.update_changeset(step, %{step_type: "llm_inference"}).valid?
    end
  end

  describe "structured_inference" do
    @fields %{
      "type" => "object",
      "properties" => %{"approved" => %{"type" => "boolean"}}
    }

    defp structured(config) do
      create(%{
        step_type: "structured_inference",
        config:
          Map.merge(
            %{
              "provider" => "typesafe",
              "model" => "jev-latest",
              "state" => "{{ task.title }}",
              "fields" => @fields
            },
            config
          )
      })
    end

    test "accepts a string, object, or array state with any provider" do
      for state <- ["{{ task.title }}", %{"a" => "{{ inputs.a? }}"}, ["x", "{{ task.tags }}"]] do
        changeset = structured(%{"state" => state, "provider" => "gliner"})
        assert changeset.valid?

        assert %Config.StructuredInference{version: 1, provider: "gliner", state: ^state} =
                 get_field(changeset, :config)
      end
    end

    test "requires provider, model, state, and fields" do
      assert %{config: errors} =
               errors_on(create(%{step_type: "structured_inference", config: %{}}))

      assert errors == %{
               provider: ["can't be blank"],
               model: ["can't be blank"],
               state: ["can't be blank"],
               fields: ["can't be blank"]
             }
    end

    test "rejects non-JSON-content state, malformed references, and invalid schemas" do
      assert %{config: %{state: ["must be a string, object, or array"]}} =
               errors_on(structured(%{"state" => 42}))

      assert %{config: %{state: ["$.state: contains a malformed interpolation"]}} =
               errors_on(structured(%{"state" => "{{ task.title"}))

      assert %{config: %{fields: ["must be a valid JSON Schema"]}} =
               errors_on(structured(%{"fields" => %{"type" => "not-a-type"}}))

      assert %{config: [message]} = errors_on(structured(%{"prompt" => "Go"}))
      assert message == "$.prompt: is not supported for structured_inference steps"
    end

    test "uses fields as the output schema for artifact persistence" do
      changeset =
        create(%{
          step_type: "structured_inference",
          persistence_options: %{"artifact" => %{"logical_name" => "judgment"}},
          config: %{
            "provider" => "typesafe",
            "model" => "jev-latest",
            "state" => "x",
            "fields" => @fields
          }
        })

      assert changeset.valid?
      assert WorkflowStep.output_schema(apply_changes(changeset)) == @fields
    end
  end
end
