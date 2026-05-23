defmodule Sacrum.Repo.AuthoringTemplateSeedsTest do
  use Sacrum.DataCase, async: false

  alias Sacrum.Repo.AuthoringTemplates
  alias Sacrum.Repo.Schemas.WorkflowStep

  @starter_drafts [
    %{
      run_kind: "feature_exploration",
      artifact_type: "task_draft",
      state_machine_entrypoint: "start_minimal_feature_exploration",
      name: "minimal_feature_exploration",
      apply_target: "task"
    },
    %{
      run_kind: "work_breakdown",
      artifact_type: "task_draft",
      state_machine_entrypoint: "start_work_breakdown_authoring",
      name: "work_breakdown_authoring",
      apply_target: "task_tree"
    },
    %{
      run_kind: "code_factory",
      artifact_type: "workflow_draft",
      state_machine_entrypoint: "start_code_factory_creation",
      name: "code_factory_creation",
      apply_target: "workflow_bundle"
    },
    %{
      run_kind: "investigation_session",
      artifact_type: "investigation_draft",
      state_machine_entrypoint: "start_investigation_session_authoring",
      name: "investigation_session_authoring",
      apply_target: "investigation_session"
    }
  ]

  @code_factory_classification %{
    run_kind: "code_factory",
    artifact_type: "workflow_draft",
    state_machine_entrypoint: "start_code_factory_creation"
  }
  @work_breakdown_classification %{
    run_kind: "work_breakdown",
    artifact_type: "task_draft",
    state_machine_entrypoint: "start_work_breakdown_authoring"
  }
  @work_breakdown_required_section_keys ["desired_behavior", "testing_criteria"]

  setup do
    Code.eval_file("priv/repo/seeds.exs")
    :ok
  end

  describe "starter draft seed records" do
    test "persist conversation entrypoint drafts with structured authoring state" do
      for draft <- @starter_drafts do
        classification = Map.put(draft, :template_kind, "starter_draft")

        assert {:ok, template} =
                 AuthoringTemplates.get_by_classification_and_name(classification, draft.name)

        assert template.payload["state_machine_entrypoint"] == draft.state_machine_entrypoint
        assert template.payload["apply_target"] == draft.apply_target

        assert %{
                 "assumptions" => assumptions,
                 "open_questions" => open_questions,
                 "proposed_approach" => proposed_approach,
                 "candidate_work_units" => candidate_work_units,
                 "validation_expectations" => validation_expectations
               } = template.payload

        assert is_list(assumptions) and length(assumptions) >= 2
        assert is_list(open_questions) and length(open_questions) >= 2
        assert is_list(proposed_approach) and length(proposed_approach) >= 2
        assert is_list(candidate_work_units) and length(candidate_work_units) >= 2
        assert is_list(validation_expectations) and length(validation_expectations) >= 2

        assert Enum.all?(candidate_work_units, fn unit ->
                 match?(
                   %{
                     "title" => title,
                     "level" => level,
                     "desired_behavior" => desired_behavior,
                     "testing_criteria" => criteria
                   }
                   when is_binary(title) and title != "" and level in ["epic", "ticket", "task"] and
                          is_binary(desired_behavior) and desired_behavior != "" and
                          is_list(criteria) and
                          criteria != [],
                   unit
                 )
               end)
      end
    end
  end

  describe "work-breakdown supporting seed records" do
    test "ships app-owned section templates and validation policy for task authoring" do
      assert {:ok, section_template} =
               AuthoringTemplates.get_by_classification_and_name(
                 Map.put(@work_breakdown_classification, :template_kind, "section_template"),
                 "work_breakdown_authoring_sections"
               )

      assert %{
               "required_sections" => required_sections,
               "required_section_templates" => required_section_templates
             } = section_template.payload

      assert Enum.map(required_sections, & &1["key"]) == @work_breakdown_required_section_keys

      assert Enum.map(required_section_templates, & &1["key"]) ==
               @work_breakdown_required_section_keys

      for template <- required_section_templates do
        assert template["key"] in @work_breakdown_required_section_keys
        assert is_binary(template["title"]) and template["title"] != ""
        assert template["required"] == true
        assert "ticket" in template["applies_to"]
        assert "task" in template["applies_to"]
        assert is_binary(template["template"]) and template["template"] != ""
      end

      assert {:ok, validation_policy} =
               AuthoringTemplates.get_by_classification_and_name(
                 Map.put(@work_breakdown_classification, :template_kind, "validation_policy"),
                 "work_breakdown_authoring_validation"
               )

      assert %{"validation_expectations" => validation_expectations} =
               validation_policy.payload

      assert is_list(validation_expectations)
      assert length(validation_expectations) >= 2
      assert Enum.any?(validation_expectations, &String.contains?(&1, "desired behavior"))
      assert Enum.any?(validation_expectations, &String.contains?(&1, "testing criteria"))
    end
  end

  describe "code-factory seed records" do
    test "represents workflows, steps, schemas, prompts, and transitions as structured data" do
      assert {:ok, recipe} =
               AuthoringTemplates.get_by_classification_and_name(
                 Map.put(@code_factory_classification, :template_kind, "workflow_recipe"),
                 "code_factory_workflows"
               )

      assert %{"workflows" => workflows, "transitions" => workflow_transitions} = recipe.payload

      workflow_by_key = Map.new(workflows, &{&1["key"], &1})

      for key <- ["backlog", "implementation", "verification", "ship", "done"] do
        assert %{
                 "name" => name,
                 "auto_advance" => auto_advance,
                 "steps" => steps
               } = workflow_by_key[key]

        assert is_binary(name) and name != ""
        assert is_boolean(auto_advance)
        assert is_list(steps) and steps != []
      end

      implementation_steps = workflow_by_key["implementation"]["steps"]

      assert Enum.map(implementation_steps, & &1["key"]) == [
               "scaffold",
               "implement",
               "eval",
               "route"
             ]

      route_step = Enum.find(implementation_steps, &(&1["key"] == "route"))

      assert route_step["type"] == "route"
      refute route_step["final"]

      assert route_step["output_schema"] ==
               WorkflowStep.routing_contract_schema(%{
                 "type" => "object",
                 "properties" => %{},
                 "required" => [],
                 "additionalProperties" => false
               })

      assert route_step["transitions_to"] == ["implementation.implement"]

      assert Enum.any?(workflow_transitions, fn transition ->
               transition == %{
                 "from" => "implementation",
                 "to" => "verification",
                 "label" => "implementation_complete",
                 "target_step" => "verification.review"
               }
             end)

      assert Enum.any?(workflow_transitions, fn transition ->
               transition == %{
                 "from" => "verification",
                 "to" => "implementation",
                 "label" => "alignment_gaps",
                 "target_step" => "implementation.implement"
               }
             end)
    end

    test "persists guarded Liquid prompt rules and schema directives from structured records" do
      assert {:ok, prompts} =
               AuthoringTemplates.get_by_classification_and_name(
                 Map.put(@code_factory_classification, :template_kind, "prompt_template"),
                 "code_factory_step_prompts"
               )

      assert %{"prompts" => prompt_records, "rules" => rules} = prompts.payload

      assert rules == %{
               "task_scope" => "Use task.* fields rather than ticket.* aliases.",
               "guard_variables" =>
                 "Guard every optional variable or section before printing it.",
               "schema_directive" =>
                 "Eval and route prompts must ask for JSON matching workflow.output_schema."
             }

      for prompt <- prompt_records do
        assert %{
                 "workflow" => workflow,
                 "step" => step,
                 "template" => template,
                 "requires_output_schema_directive" => requires_schema_directive
               } = prompt

        assert is_binary(workflow) and workflow != ""
        assert is_binary(step) and step != ""
        assert String.contains?(template, "task.")
        refute String.contains?(template, "ticket.")
        assert task_references_are_guarded?(template)
        assert requires_schema_directive == step in ["eval", "route"]

        if requires_schema_directive do
          assert String.contains?(template, "{% if workflow.output_schema %}")
          assert String.contains?(template, "{{ workflow.output_schema }}")
        end
      end
    end
  end

  defp task_references_are_guarded?(template) do
    ~r/{%\s*if\s+task\.[^%]+%}/
    |> Regex.scan(template)
    |> Enum.any?()
  end
end
