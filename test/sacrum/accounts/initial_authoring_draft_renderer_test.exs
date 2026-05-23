defmodule Sacrum.Accounts.InitialAuthoringDraftRendererTest do
  use ExUnit.Case, async: true

  alias Sacrum.Accounts.InitialAuthoringDraftRenderer
  alias Sacrum.Repo.Schemas.WorkflowStep

  describe "render/2" do
    test "renders a feature/work-breakdown authoring template into an unsaved initial draft payload" do
      template = work_breakdown_template()

      assert {:ok, draft} =
               InitialAuthoringDraftRenderer.render(template,
                 state_machine_id: "feature_authoring",
                 initial_state: "collect_scope",
                 revision: 4
               )

      assert Map.drop(draft, [:payload]) == %{
               status: :draft,
               persisted?: false,
               state_machine_id: "feature_authoring",
               state_machine_entrypoint: "start_work_breakdown_authoring",
               initial_state: "collect_scope",
               revision: %{source: "authoring_template", value: 4},
               template: %{
                 name: "work_breakdown_authoring",
                 run_kind: "work_breakdown",
                 artifact_type: "task_draft",
                 template_kind: "starter_draft"
               }
             }

      assert draft.payload.assumptions == [
               "The requested feature belongs in the current project.",
               "Existing workflow boundaries should be preserved unless the user asks otherwise."
             ]

      assert [
               %{
                 title: "Render state-machine authoring draft",
                 level: "ticket",
                 desired_behavior:
                   "Pure rendering returns the initial authoring payload without persistence.",
                 testing_criteria: [
                   "Structured input maps produce stable assumptions and work-unit output."
                 ]
               }
             ] = draft.payload.candidate_work_units

      assert Enum.map(draft.payload.required_section_templates, & &1.key) == [
               "desired_behavior",
               "testing_criteria"
             ]

      assert Enum.map(draft.payload.required_sections, & &1.key) == [
               "desired_behavior",
               "testing_criteria"
             ]

      assert draft.payload.apply_targets == [
               %{kind: "task", mode: "update_existing"},
               %{kind: "task_tree", mode: "create_children"}
             ]

      assert draft.payload.apply_target == "task_tree"
      assert draft.payload.proposed_approach == ["Create a draft.", "Ask for validation."]
    end

    test "renders a seeded minimal code-factory recipe with guarded Liquid prompts and valid routing targets" do
      template = code_factory_recipe_template()

      assert {:ok, draft} =
               InitialAuthoringDraftRenderer.render(template,
                 state_machine_id: "workflow_factory",
                 initial_state: "draft_recipe",
                 revision: 2
               )

      assert %{payload: %{workflows: workflows, transitions: transitions}} = draft
      assert workflow_keys(workflows) == ["implementation", "verification"]

      implementation = workflow_by_key(workflows, "implementation")
      assert Enum.map(implementation.steps, & &1.key) == ["work", "eval", "route"]

      work_step = step_by_key(implementation.steps, "work")
      eval_step = step_by_key(implementation.steps, "eval")
      route_step = step_by_key(implementation.steps, "route")

      assert work_step.type == "work"
      assert eval_step.type == "eval"
      assert route_step.type == "route"

      for step <- [work_step, eval_step, route_step] do
        assert String.contains?(step.prompt, "{% if task.title %}")
        assert String.contains?(step.prompt, "{{ task.title }}")
        refute String.contains?(step.prompt, "{{ ticket.")
      end

      assert String.contains?(eval_step.prompt, "{% if workflow.output_schema %}")
      assert String.contains?(route_step.prompt, "{% if workflow.output_schema %}")

      assert route_step.output_schema == WorkflowStep.routing_contract_schema()

      assert route_step.transitions_to == ["implementation.work", "verification.review"]

      assert transitions == [
               %{
                 from: "implementation",
                 to: "verification",
                 label: "ready_for_review",
                 target_step: "verification.review"
               }
             ]
    end
  end

  defp work_breakdown_template do
    %{
      run_kind: "work_breakdown",
      artifact_type: "task_draft",
      template_kind: "starter_draft",
      state_machine_entrypoint: "start_work_breakdown_authoring",
      name: "work_breakdown_authoring",
      payload: %{
        assumptions: [
          "The requested feature belongs in the current project.",
          "Existing workflow boundaries should be preserved unless the user asks otherwise."
        ],
        open_questions: [
          "Which user path must be supported first?",
          "What validation signal proves the breakdown is correct?"
        ],
        candidate_work_units: [
          %{
            title: "Render state-machine authoring draft",
            level: "ticket",
            desired_behavior:
              "Pure rendering returns the initial authoring payload without persistence.",
            testing_criteria: [
              "Structured input maps produce stable assumptions and work-unit output."
            ]
          }
        ],
        required_section_templates: [
          %{
            key: "desired_behavior",
            title: "Desired Behavior",
            required: true,
            applies_to: ["ticket", "task"]
          },
          %{
            key: "testing_criteria",
            title: "Testing Criteria",
            required: true,
            applies_to: ["ticket", "task"]
          }
        ],
        apply_targets: [
          %{kind: "task", mode: "update_existing"},
          %{kind: "task_tree", mode: "create_children"}
        ],
        apply_target: "task_tree",
        proposed_approach: ["Create a draft.", "Ask for validation."],
        required_sections: [
          %{"key" => "desired_behavior", "required" => true},
          %{"key" => "testing_criteria", "required" => true}
        ],
        validation_expectations: [
          "Every candidate work unit includes concrete testing criteria.",
          "Required section templates are present before apply."
        ]
      }
    }
  end

  defp code_factory_recipe_template do
    %{
      run_kind: "code_factory",
      artifact_type: "workflow_draft",
      template_kind: "workflow_recipe",
      state_machine_entrypoint: "start_code_factory_creation",
      name: "code_factory_creation",
      payload: %{
        workflows: [
          %{
            key: "implementation",
            name: "Implementation",
            initial_step: "work",
            auto_advance: true,
            steps: [
              %{
                key: "work",
                type: "work",
                prompt: """
                {% if task.title %}Implement {{ task.title }}.{% endif %}
                {% if task.desired_behavior %}Honor {{ task.desired_behavior }}.{% endif %}
                """
              },
              %{
                key: "eval",
                type: "eval",
                prompt: """
                {% if task.title %}Evaluate {{ task.title }}.{% endif %}
                {% if workflow.output_schema %}Return JSON matching {{ workflow.output_schema }}.{% endif %}
                """
              },
              %{
                key: "route",
                type: "route",
                prompt: """
                {% if task.title %}Route {{ task.title }}.{% endif %}
                {% if workflow.output_schema %}Return JSON matching {{ workflow.output_schema }}.{% endif %}
                """,
                output_schema: WorkflowStep.routing_contract_schema(),
                transitions_to: ["implementation.work", "verification.review"]
              }
            ]
          },
          %{
            key: "verification",
            name: "Verification",
            initial_step: "review",
            steps: [
              %{
                key: "review",
                type: "eval",
                prompt: """
                {% if task.title %}Review {{ task.title }}.{% endif %}
                {% if workflow.output_schema %}Return JSON matching {{ workflow.output_schema }}.{% endif %}
                """
              }
            ]
          }
        ],
        transitions: [
          %{
            from: "implementation",
            to: "verification",
            label: "ready_for_review",
            target_step: "verification.review"
          }
        ]
      }
    }
  end

  defp workflow_keys(workflows), do: Enum.map(workflows, & &1.key)

  defp workflow_by_key(workflows, key), do: Enum.find(workflows, &(&1.key == key))

  defp step_by_key(steps, key), do: Enum.find(steps, &(&1.key == key))
end
