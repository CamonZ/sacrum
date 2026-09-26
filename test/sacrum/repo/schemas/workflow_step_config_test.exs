defmodule Sacrum.Repo.Schemas.WorkflowStepConfigTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.Schemas.WorkflowStep
  alias Sacrum.Repo.Schemas.WorkflowStep.Config
  alias Sacrum.Routing.{RouteConfig, RoutePredecessors}

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
    @questions %{
      "ready" => %{"type" => "noul", "instructions" => "Is the task ready?"},
      "area" => %{
        "type" => "choice",
        "instructions" => "Which area does the task touch?",
        "criteria" => %{"api" => "Server code", "ui" => nil}
      },
      "risk" => %{
        "type" => "score",
        "instructions" => %{"assess" => "risk"},
        "criteria" => ["low", "medium", "high"]
      }
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
              "questions" => @questions
            },
            config
          )
      })
    end

    defp question_errors(questions) do
      case errors_on(structured(%{"questions" => questions})) do
        %{config: %{questions: errors}} -> errors
        _valid -> []
      end
    end

    test "accepts a string, object, or array state with any provider" do
      for state <- ["{{ task.title }}", %{"a" => "{{ inputs.a? }}"}, ["x", "{{ task.tags }}"]] do
        changeset = structured(%{"state" => state, "provider" => "gliner"})
        assert changeset.valid?

        assert %Config.StructuredInference{
                 version: 1,
                 provider: "gliner",
                 state: ^state,
                 questions: @questions
               } = get_field(changeset, :config)
      end
    end

    test "requires provider, model, state, and questions" do
      assert %{config: errors} =
               errors_on(create(%{step_type: "structured_inference", config: %{}}))

      assert errors == %{
               provider: ["can't be blank"],
               model: ["can't be blank"],
               state: ["can't be blank"],
               questions: ["can't be blank"]
             }
    end

    test "rejects non-JSON-content state, malformed references, and undeclared keys" do
      assert %{config: %{state: ["must be a string, object, or array"]}} =
               errors_on(structured(%{"state" => 42}))

      assert %{config: %{state: ["$.state: contains a malformed interpolation"]}} =
               errors_on(structured(%{"state" => "{{ task.title"}))

      for key <- ["prompt", "fields"] do
        assert %{config: [message]} = errors_on(structured(%{key => %{}}))
        assert message == "$.#{key}: is not supported for structured_inference steps"
      end
    end

    test "accepts each question type with optional and nullable criteria" do
      assert question_errors(@questions) == []

      assert question_errors(%{
               "flag" => %{
                 "type" => "noul",
                 "instructions" => ["Check", "this"],
                 "criteria" => %{"true" => "Yes", "false" => %{"means" => "no"}}
               },
               "one" => %{
                 "type" => "choice",
                 "instructions" => "Pick",
                 "criteria" => %{"a" => nil}
               },
               "two" => %{"type" => "score", "instructions" => "Rate", "criteria" => ["lo", "hi"]}
             }) == []
    end

    test "normalizes question and choice keys and preserves authored option labels" do
      questions = %{
        "Needs changes" => %{
          "type" => "choice",
          "instructions" => "Pick",
          "criteria" => %{"Needs changes" => nil, "already_snake_case" => "Given"}
        },
        "Sí.version-2" => %{"type" => "noul", "instructions" => "Check"}
      }

      changeset = structured(%{"questions" => questions})
      assert changeset.valid?

      assert %Config.StructuredInference{questions: normalized} = get_field(changeset, :config)

      assert normalized["needs_changes"]["criteria"] == %{
               "needs_changes" => "Needs changes",
               "already_snake_case" => "Given"
             }

      assert normalized["si_version_2"]

      schema = Config.StructuredInference.answers_schema(normalized)
      assert schema["required"] == ["needs_changes", "si_version_2"]

      assert schema["properties"]["needs_changes"]["properties"]["probabilities"]["required"] ==
               ["already_snake_case", "needs_changes"]

      {:ok, route} =
        RouteConfig.decode(%{
          "version" => 1,
          "match_policy" => "exactly_one",
          "rules" => [
            %{
              "id" => "normalized-answer",
              "when" => %{
                "ref" => "previous_output.needs_changes.probabilities.needs_changes",
                "op" => "gte",
                "value" => 0.7
              },
              "transition" => %{"type" => "intra_workflow", "step_id" => Ecto.UUID.generate()}
            }
          ],
          "default" => %{
            "transition" => %{"type" => "intra_workflow", "step_id" => Ecto.UUID.generate()}
          }
        })

      assert {:ok, environment} =
               RoutePredecessors.derive_type_environment([
                 %{
                   output_schema: schema,
                   step_type: :structured_inference,
                   transition_id: "inference"
                 }
               ])

      assert :ok = RoutePredecessors.validate(route, environment)
    end

    test "rejects keys that normalize to empty strings or collide" do
      assert ["$.questions.???: question id normalizes to an empty key"] =
               question_errors(%{"???" => %{"type" => "noul", "instructions" => "x"}})

      assert [message] =
               question_errors(%{
                 "q" => %{
                   "type" => "choice",
                   "instructions" => "x",
                   "criteria" => %{"Needs changes" => nil, "needs-changes" => nil}
                 }
               })

      assert message =~ "$.questions.q.criteria.needs-changes"
      assert message =~ "collides after normalization as needs_changes"

      assert [message] =
               question_errors(%{
                 "Needs changes" => %{"type" => "noul", "instructions" => "x"},
                 "needs-changes" => %{"type" => "noul", "instructions" => "x"}
               })

      assert message =~ "collides after normalization as needs_changes"
    end

    test "rejects invalid questions with the config path" do
      cases = [
        {%{}, "$.questions: must not be empty"},
        {%{" " => @questions["ready"]}, "$.questions. : question id normalizes to an empty key"},
        {%{"q" => "noul"}, "$.questions.q: must be an object"},
        {%{"q" => %{"type" => "entity", "instructions" => "x"}},
         "$.questions.q.type: must be one of noul, choice, score"},
        {%{"q" => %{"type" => "noul"}},
         "$.questions.q.instructions: must be a non-blank string, object, or array"},
        {%{"q" => %{"type" => "noul", "instructions" => "  "}},
         "$.questions.q.instructions: must be a non-blank string, object, or array"},
        {%{"q" => %{"type" => "noul", "instructions" => "x", "criteria" => %{"maybe" => "?"}}},
         "$.questions.q.criteria.maybe: noul criteria may only contain true and false"},
        {%{"q" => %{"type" => "noul", "instructions" => "x", "criteria" => %{"true" => 1}}},
         "$.questions.q.criteria.true: must be a non-blank string, object, or array"},
        {%{"q" => %{"type" => "choice", "instructions" => "x"}},
         "$.questions.q.criteria: must be an object with 1 to 255 options"},
        {%{"q" => %{"type" => "choice", "instructions" => "x", "criteria" => %{}}},
         "$.questions.q.criteria: must be an object with 1 to 255 options"},
        {%{
           "q" => %{
             "type" => "choice",
             "instructions" => "x",
             "criteria" => Map.new(1..256, &{"o#{&1}", nil})
           }
         }, "$.questions.q.criteria: must be an object with 1 to 255 options"},
        {%{"q" => %{"type" => "choice", "instructions" => "x", "criteria" => %{"" => nil}}},
         "$.questions.q.criteria.: option normalizes to an empty key"},
        {%{"q" => %{"type" => "choice", "instructions" => "x", "criteria" => %{"a" => ""}}},
         "$.questions.q.criteria.a: must be a non-blank string, object, or array"},
        {%{"q" => %{"type" => "score", "instructions" => "x", "criteria" => ["only"]}},
         "$.questions.q.criteria: must be an array of 2 to 10 levels"},
        {%{
           "q" => %{
             "type" => "score",
             "instructions" => "x",
             "criteria" => Enum.map(1..11, &"l#{&1}")
           }
         }, "$.questions.q.criteria: must be an array of 2 to 10 levels"},
        {%{"q" => %{"type" => "score", "instructions" => "x", "criteria" => ["lo", nil]}},
         "$.questions.q.criteria[1]: must be a non-blank string, object, or array"}
      ]

      for {questions, message} <- cases do
        assert question_errors(questions) == [message], "for #{inspect(questions)}"
      end
    end

    test "derives a strict answers schema from the questions" do
      schema = WorkflowStep.output_schema(apply_changes(structured(%{})))
      probability = %{"type" => "number", "minimum" => 0, "maximum" => 1}

      assert schema["required"] == ["area", "ready", "risk"]
      assert schema["additionalProperties"] == false

      assert schema["properties"]["ready"] == %{
               "type" => "object",
               "properties" => %{
                 "type" => %{"type" => "string", "enum" => ["noul"]},
                 "noul" => probability
               },
               "required" => ["type", "noul"]
             }

      area = schema["properties"]["area"]
      assert area["required"] == ["type", "choice", "confidence", "probabilities"]
      assert area["properties"]["choice"] == %{"type" => "string", "enum" => ["api", "ui"]}
      assert area["properties"]["confidence"] == probability

      assert area["properties"]["probabilities"] == %{
               "type" => "object",
               "properties" => %{"api" => probability, "ui" => probability},
               "required" => ["api", "ui"],
               "additionalProperties" => false
             }

      risk = schema["properties"]["risk"]
      assert risk["required"] == ["type", "confidence", "legend", "probabilities", "score"]
      assert risk["properties"]["score"] == %{"type" => "number", "minimum" => 0, "maximum" => 2}
      assert risk["properties"]["legend"]["required"] == ["0", "1", "2"]
      assert risk["properties"]["legend"]["properties"]["0"] == %{"type" => "string"}
      assert risk["properties"]["probabilities"]["required"] == ["0", "1", "2"]
      refute Map.has_key?(risk, "additionalProperties")
    end

    test "uses the answers schema for artifact persistence" do
      changeset =
        create(%{
          step_type: "structured_inference",
          persistence_options: %{"artifact" => %{"logical_name" => "judgment"}},
          config: %{
            "provider" => "typesafe",
            "model" => "jev-latest",
            "state" => "x",
            "questions" => @questions
          }
        })

      assert changeset.valid?

      assert WorkflowStep.output_schema(apply_changes(changeset)) ==
               Config.StructuredInference.answers_schema(@questions)
    end
  end
end
