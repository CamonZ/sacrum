defmodule Sacrum.TestSupport.AuthoringFixtures do
  @moduledoc false

  alias Sacrum.Accounts.Artifacts
  alias Sacrum.Repo.AuthoringTemplates

  @code_factory %{
    run_kind: "code_factory",
    artifact_type: "workflow_draft",
    template_kind: "workflow_recipe",
    state_machine_entrypoint: "start_code_factory_creation",
    state_machine_id: "code_factory_creation",
    initial_state: "collect_workflow_goal"
  }
  @feature_exploration %{
    run_kind: "feature_exploration",
    artifact_type: "task_draft",
    template_kind: "starter_draft",
    state_machine_entrypoint: "start_minimal_feature_exploration",
    state_machine_id: "feature_exploration",
    initial_state: "collect_feature_scope"
  }
  @investigation_session %{
    run_kind: "investigation_session",
    artifact_type: "investigation_draft",
    template_kind: "starter_draft",
    state_machine_entrypoint: "start_investigation_session_authoring",
    state_machine_id: "investigation_session_authoring",
    initial_state: "collect_investigation_scope"
  }

  def insert_code_factory_template!(attrs \\ %{}) do
    insert_authoring_template!(
      @code_factory,
      "code_factory_creation",
      code_factory_template_payload(),
      attrs
    )
  end

  def insert_feature_exploration_template!(attrs \\ %{}) do
    insert_authoring_template!(
      @feature_exploration,
      "minimal_feature_exploration",
      feature_exploration_template_payload(),
      attrs
    )
  end

  def insert_investigation_session_template!(attrs \\ %{}) do
    insert_authoring_template!(
      @investigation_session,
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

  def code_factory_start_intent(source_message_id, overrides \\ %{}) do
    @code_factory
    |> start_authoring_intent(source_message_id, %{"tool" => "workflow.create_from_recipe"})
    |> Map.merge(overrides)
  end

  def feature_start_intent(source_message_id, overrides \\ %{}) do
    start_authoring_intent(@feature_exploration, source_message_id, overrides)
  end

  def investigation_start_intent(source_message_id, overrides \\ %{}) do
    start_authoring_intent(@investigation_session, source_message_id, overrides)
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

  def code_factory_template_payload do
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

    {:ok, template} = AuthoringTemplates.insert(deep_merge(base_attrs, attrs))
    template
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
