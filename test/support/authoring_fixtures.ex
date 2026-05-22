defmodule Sacrum.TestSupport.AuthoringFixtures do
  @moduledoc false

  alias Sacrum.Accounts.Artifacts
  alias Sacrum.Repo.AuthoringTemplates

  def insert_code_factory_template!(attrs \\ %{}) do
    base_attrs = %{
      run_kind: "code_factory",
      artifact_type: "workflow_draft",
      template_kind: "workflow_recipe",
      state_machine_entrypoint: "start_code_factory_creation",
      name: "code_factory_creation",
      payload: code_factory_template_payload()
    }

    {:ok, template} = AuthoringTemplates.insert(deep_merge(base_attrs, attrs))
    template
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
    Map.merge(
      %{
        "action" => "start_authoring",
        "tool" => "workflow.create_from_recipe",
        "run_kind" => "code_factory",
        "artifact_type" => "workflow_draft",
        "template_kind" => "workflow_recipe",
        "state_machine_entrypoint" => "start_code_factory_creation",
        "state_machine_id" => "code_factory_creation",
        "initial_state" => "collect_workflow_goal",
        "source_message_id" => source_message_id
      },
      overrides
    )
  end

  def feature_start_intent(source_message_id, overrides \\ %{}) do
    Map.merge(
      %{
        "action" => "start_authoring",
        "run_kind" => "work_breakdown",
        "artifact_type" => "task_draft",
        "template_kind" => "starter_draft",
        "state_machine_entrypoint" => "start_work_breakdown_authoring",
        "state_machine_id" => "feature_authoring",
        "initial_state" => "discovery",
        "source_message_id" => source_message_id
      },
      overrides
    )
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
