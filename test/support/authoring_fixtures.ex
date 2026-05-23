defmodule Sacrum.TestSupport.AuthoringFixtures do
  @moduledoc false

  alias Sacrum.Accounts.{Artifacts, AuthoringRunKinds, LiveChat, Projects}
  alias Sacrum.Repo
  alias Sacrum.Repo.AuthoringTemplates
  alias Sacrum.Repo.Schemas.AuthoringTemplate
  alias Sacrum.Repo.Users

  defp work_breakdown, do: AuthoringRunKinds.work_breakdown()
  defp code_factory, do: AuthoringRunKinds.code_factory()
  defp feature_exploration, do: AuthoringRunKinds.feature_exploration()
  defp investigation_session, do: AuthoringRunKinds.investigation_session()

  def insert_code_factory_template!(attrs \\ %{}) do
    # AuthoringTemplateLookup resolves a code_factory start_authoring request by
    # joining three rows: the starter_draft descriptor that the chat-side enums
    # advertise, plus the workflow_recipe and prompt_template supporting rows
    # that enrich_code_factory_template/3 merges in. The seeds file inserts the
    # same three rows; tests insert their own so the suite does not depend on
    # priv/repo/seeds.exs having been evaluated against the test DB.
    descriptor = code_factory()

    starter =
      insert_authoring_template!(
        descriptor,
        "code_factory_creation",
        code_factory_starter_payload(),
        attrs
      )

    insert_authoring_template!(
      %{descriptor | template_kind: "workflow_recipe"},
      "code_factory_workflows",
      code_factory_workflow_recipe_payload(),
      attrs
    )

    insert_authoring_template!(
      %{descriptor | template_kind: "prompt_template"},
      "code_factory_step_prompts",
      code_factory_prompt_template_payload(),
      attrs
    )

    starter
  end

  def insert_feature_exploration_template!(attrs \\ %{}) do
    insert_authoring_template!(
      feature_exploration(),
      "minimal_feature_exploration",
      feature_exploration_template_payload(),
      attrs
    )
  end

  def insert_investigation_session_template!(attrs \\ %{}) do
    insert_authoring_template!(
      investigation_session(),
      "investigation_session_authoring",
      investigation_session_template_payload(),
      attrs
    )
  end

  def insert_work_breakdown_authoring_templates! do
    starter =
      insert_work_breakdown_template!("starter_draft", %{
        "state_machine_entrypoint" => "start_work_breakdown_authoring",
        "apply_target" => "task_tree",
        "candidate_work_units" => [
          %{
            "title" => "Define parent outcome",
            "level" => "ticket",
            "desired_behavior" => "State the behavior the breakdown must deliver.",
            "testing_criteria" => ["Parent scope is clear enough to judge child coverage."]
          }
        ]
      })

    section_template =
      insert_work_breakdown_template!("section_template", %{
        "scope" => %{"project_id" => nil},
        "required_sections" => [
          %{"key" => "desired_behavior", "title" => "Desired Behavior", "required" => true},
          %{"key" => "testing_criteria", "title" => "Testing Criteria", "required" => true}
        ],
        "required_section_templates" => [
          %{
            "key" => "desired_behavior",
            "title" => "Desired Behavior",
            "required" => true,
            "applies_to" => ["ticket", "task"],
            "template" => "Describe the externally visible behavior this work must deliver."
          },
          %{
            "key" => "testing_criteria",
            "title" => "Testing Criteria",
            "required" => true,
            "applies_to" => ["ticket", "task"],
            "template" => "List concrete checks that prove the behavior works."
          }
        ]
      })

    validation_policy =
      insert_work_breakdown_template!("validation_policy", %{
        "scope" => %{"project_id" => nil},
        "validation_expectations" => [
          "Every candidate unit has desired behavior.",
          "Every candidate unit has testing criteria.",
          "Required section templates are persisted for apply validation."
        ]
      })

    %{starter: starter, section_template: section_template, validation_policy: validation_policy}
  end

  def seeded_authoring_session!(prefix, project_name) do
    Code.eval_file("priv/repo/seeds.exs")

    suffix = System.unique_integer([:positive])
    username_prefix = String.replace(prefix, "-", "_")

    {:ok, user} =
      Users.insert(%{
        email: "#{prefix}-#{suffix}@example.com",
        username: "#{username_prefix}_#{suffix}",
        password: "password123"
      })

    {:ok, project} = Projects.insert(user.id, %{name: project_name})
    {:ok, session} = LiveChat.create_session(user.id, project.id, %{})

    %{user: user, project: project, session: session}
  end

  def work_breakdown_start_intent(source_message_id, overrides \\ %{}) do
    work_breakdown()
    |> start_authoring_intent(source_message_id, %{})
    |> Map.merge(overrides)
  end

  def code_factory_start_intent(source_message_id, overrides \\ %{}) do
    code_factory()
    |> start_authoring_intent(source_message_id, %{"tool" => "workflow.create_from_recipe"})
    |> Map.merge(overrides)
  end

  def feature_start_intent(source_message_id, overrides \\ %{}) do
    start_authoring_intent(feature_exploration(), source_message_id, overrides)
  end

  def investigation_start_intent(source_message_id, overrides \\ %{}) do
    start_authoring_intent(investigation_session(), source_message_id, overrides)
  end

  def revise_authoring_intent(state_machine_id, source_message_id, overrides \\ %{}) do
    Map.merge(
      %{
        "action" => "revise_authoring",
        "state_machine_id" => state_machine_id,
        "source_message_id" => source_message_id
      },
      overrides
    )
  end

  def authoring_drafts_for_session(user, project, session) do
    user.id
    |> Artifacts.list_for_subject(project.id, "chat_session", session.id)
    |> Enum.filter(&(&1.artifact_type == "authoring_draft"))
    |> Enum.sort_by(&{&1.inserted_at, &1.id})
  end

  def authoring_drafts_for_session(%{user: user, project: project, session: session}) do
    authoring_drafts_for_session(user, project, session)
  end

  def workflow_by_key(workflows, key), do: Enum.find(workflows, &(&1["key"] == key))

  def step_by_key(steps, key), do: Enum.find(steps, &(&1["key"] == key))

  def code_factory_starter_payload do
    %{
      "state_machine_entrypoint" => "start_code_factory_creation",
      "apply_target" => "workflow_bundle",
      "assumptions" => [
        "The factory follows work steps, eval, then route.",
        "Route steps drive transitions through structured output."
      ],
      "open_questions" => [
        "Which workflow should receive aligned implementation output?",
        "Which eval criteria decide whether work routes forward or loops?"
      ],
      "proposed_approach" => [
        "Initialize only the known Code Factory workflow bundle shape.",
        "Constrain route and eval prompts with schema-backed JSON output."
      ],
      "candidate_work_units" => [
        %{
          "title" => "Draft Code Factory workflow bundle",
          "level" => "ticket",
          "desired_behavior" =>
            "Represent backlog, implementation, verification, ship, and done workflows.",
          "testing_criteria" => ["Each workflow has at least one structured step."]
        }
      ],
      "validation_expectations" => [
        "Route steps are not final unless they are true terminal steps.",
        "Eval and route prompts include workflow.output_schema directives."
      ]
    }
  end

  def code_factory_workflow_recipe_payload do
    %{
      "workflows" => [
        %{
          "key" => "implementation",
          "name" => "Implementation",
          "initial_step" => "work",
          "steps" => [
            %{
              "key" => "work",
              "type" => "work",
              "prompt" => "{% if task.title %}Implement {{ task.title }}.{% endif %}",
              "output_schema" => %{
                "type" => "object",
                "required" => ["summary"],
                "properties" => %{"summary" => %{"type" => "string"}}
              }
            }
          ]
        }
      ],
      "transitions" => [
        %{
          "from" => "implementation",
          "to" => "verification",
          "label" => "ready_for_review",
          "target_step" => "verification.review"
        }
      ],
      "validation_expectations" => [
        "Every workflow has an initial step.",
        "Every prompt uses guarded Liquid variables."
      ]
    }
  end

  def code_factory_prompt_template_payload do
    %{
      "rules" => %{
        "task_scope" => "Use task.* fields rather than ticket.* aliases.",
        "guard_variables" => "Guard every optional variable or section before printing it.",
        "schema_directive" =>
          "Eval and route prompts must ask for JSON matching workflow.output_schema."
      },
      "prompts" => [
        %{
          "workflow" => "implementation",
          "step" => "work",
          "requires_output_schema_directive" => false,
          "template" => "Implement {{ task.title }} using the current task context."
        }
      ]
    }
  end

  def feature_exploration_template_payload do
    %{
      assumptions: [
        "The user has a feature idea but not enough implementation detail yet."
      ],
      open_questions: [
        "What user-visible behavior should change first?"
      ],
      proposed_approach: [
        "Capture the smallest useful outcome before decomposing work."
      ],
      candidate_work_units: [
        %{
          title: "Clarify minimal feature outcome",
          level: "task",
          desired_behavior: "Record the feature goal, constraints, and unknowns."
        }
      ],
      apply_target: "task",
      validation_expectations: [
        "The draft has enough detail to create or update a task."
      ]
    }
  end

  def investigation_session_template_payload do
    %{
      assumptions: [
        "The user needs to understand a behavior before deciding implementation work."
      ],
      open_questions: [
        "Which runtime path or user-visible symptom should be inspected first?"
      ],
      proposed_approach: [
        "Trace the smallest observable path from trigger to stored state."
      ],
      candidate_work_units: [
        %{
          title: "Trace investigation path",
          level: "task",
          desired_behavior: "Identify the source, update path, and observed failure mode.",
          testing_criteria: ["Investigation notes cite concrete code or runtime evidence."]
        }
      ],
      apply_target: "investigation_session",
      apply_targets: ["investigation_session"],
      validation_expectations: [
        "Assumptions and open questions remain explicit."
      ]
    }
  end

  defp insert_authoring_template!(descriptor, name, payload, attrs) do
    base_attrs =
      descriptor
      |> Map.take([:run_kind, :artifact_type, :template_kind, :state_machine_entrypoint])
      |> Map.merge(%{name: name, payload: payload})

    merged_attrs = deep_merge(base_attrs, attrs)

    case AuthoringTemplates.insert(merged_attrs) do
      {:ok, template} ->
        template

      {:error, %Ecto.Changeset{errors: errors}} = error ->
        if Keyword.has_key?(errors, :run_kind) and
             match?({_, [constraint: :unique, constraint_name: _]}, errors[:run_kind]) do
          # Seeded template already occupies this classification+name. Update its
          # payload so the fixture's data wins for the duration of the test.
          {:ok, existing} =
            AuthoringTemplates.get_by_classification_and_name(
              Map.take(merged_attrs, [
                :run_kind,
                :artifact_type,
                :template_kind,
                :state_machine_entrypoint
              ]),
              merged_attrs.name
            )

          {:ok, updated} =
            existing
            |> AuthoringTemplate.create_changeset(%{payload: merged_attrs.payload})
            |> Repo.update()

          updated
        else
          raise inspect(error)
        end
    end
  end

  defp start_authoring_intent(descriptor, source_message_id, overrides) do
    descriptor
    |> stringify_keys()
    |> Map.merge(%{
      "action" => "start_authoring",
      "source_message_id" => source_message_id
    })
    |> Map.merge(overrides)
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)

  defp insert_work_breakdown_template!(template_kind, payload) do
    {:ok, template} =
      AuthoringTemplates.insert(%{
        run_kind: "work_breakdown",
        artifact_type: "task_draft",
        template_kind: template_kind,
        state_machine_entrypoint: "start_work_breakdown_authoring",
        name: "work_breakdown_authoring_#{template_kind}",
        payload: payload
      })

    template
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge(left_value, right_value)
    end)
  end

  defp deep_merge(_left, right), do: right
end

defmodule Sacrum.TestSupport.AuthoringIntentProvider do
  @moduledoc false

  @behaviour Sacrum.Chat.Inference.Provider

  alias Sacrum.Chat.Inference.Result

  @impl true
  def generate(messages, opts) do
    if test_pid = Keyword.get(opts, :test_pid) do
      send(test_pid, {:authoring_provider_messages, messages})
    end

    {:ok,
     %Result{
       content: Keyword.fetch!(opts, :content),
       content_format: :markdown,
       public_metadata: %{
         "provider" => "fake",
         "model" => "authoring-intent-model"
       },
       internal_metadata: %{
         "authoring_tool_intent" => Keyword.fetch!(opts, :authoring_tool_intent)
       }
     }}
  end
end
