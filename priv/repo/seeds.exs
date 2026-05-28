# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Sacrum.Repo.insert!(%Sacrum.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

alias Sacrum.Repo
alias Sacrum.Repo.Schemas.AuthoringTemplate
alias Sacrum.Repo.Schemas.WorkflowStep

route_handoff_schema = %{
  "type" => "object",
  "properties" => %{},
  "required" => [],
  "additionalProperties" => false
}

eval_output_schema = %{
  "type" => "object",
  "properties" => %{},
  "required" => [],
  "additionalProperties" => false
}

route_output_schema = WorkflowStep.routing_contract_schema(route_handoff_schema)

starter_drafts = [
  %{
    run_kind: "feature_exploration",
    artifact_type: "task_draft",
    template_kind: "starter_draft",
    state_machine_entrypoint: "start_minimal_feature_exploration",
    name: "minimal_feature_exploration",
    payload: %{
      state_machine_entrypoint: "start_minimal_feature_exploration",
      apply_target: "task",
      assumptions: [
        "The user has a feature idea but not enough implementation detail yet.",
        "The authoring state machine should preserve uncertainty as questions."
      ],
      open_questions: [
        "What user-visible behavior should change?",
        "What existing workflow or surface should this extend?"
      ],
      proposed_approach: [
        "Capture the smallest useful outcome before decomposing work.",
        "Convert confirmed scope into task sections and testing criteria."
      ],
      candidate_work_units: [
        %{
          title: "Clarify minimal feature outcome",
          level: "task",
          desired_behavior: "Record the feature goal, constraints, and unknowns in a task draft.",
          testing_criteria: ["Draft includes a concrete desired behavior."]
        },
        %{
          title: "Identify validation path",
          level: "task",
          desired_behavior: "Describe how the feature can be checked once implemented.",
          testing_criteria: ["Draft includes at least one executable validation expectation."]
        }
      ],
      validation_expectations: [
        "The draft has enough detail to create or update a task.",
        "Unknowns remain explicit instead of being inferred."
      ]
    }
  },
  %{
    run_kind: "work_breakdown",
    artifact_type: "task_draft",
    template_kind: "starter_draft",
    state_machine_entrypoint: "start_work_breakdown_authoring",
    name: "work_breakdown_authoring",
    payload: %{
      state_machine_entrypoint: "start_work_breakdown_authoring",
      apply_target: "task_tree",
      assumptions: [
        "The user wants work split into vertical behavior slices.",
        "Each child unit should be independently understandable and testable."
      ],
      open_questions: [
        "Which behavior must ship first?",
        "Which dependencies force sequencing between units?"
      ],
      proposed_approach: [
        "Group work by input-to-output behavior instead of artifact type.",
        "Attach concrete testing criteria to each proposed child task."
      ],
      candidate_work_units: [
        %{
          title: "Define parent outcome",
          level: "ticket",
          desired_behavior: "State the end-to-end behavior the breakdown must deliver.",
          testing_criteria: ["Parent scope is clear enough to judge child coverage."]
        },
        %{
          title: "Create first vertical child",
          level: "task",
          desired_behavior: "Draft a child unit with behavior, constraints, and validation.",
          testing_criteria: ["Child has non-empty testing criteria."]
        }
      ],
      validation_expectations: [
        "Every candidate unit has a behavior-oriented title and criteria.",
        "Dependency order is represented without creating unrelated work."
      ]
    }
  },
  %{
    run_kind: "investigation_session",
    artifact_type: "investigation_draft",
    template_kind: "starter_draft",
    state_machine_entrypoint: "start_investigation_session_authoring",
    name: "investigation_session_authoring",
    payload: %{
      state_machine_entrypoint: "start_investigation_session_authoring",
      apply_target: "investigation_session",
      apply_targets: ["investigation_session"],
      assumptions: [
        "The user needs to understand a behavior before deciding implementation work.",
        "The investigation should preserve uncertainty until evidence is collected."
      ],
      open_questions: [
        "Which runtime path or user-visible symptom should be inspected first?",
        "What evidence would distinguish a product gap from an implementation bug?"
      ],
      proposed_approach: [
        "Trace the smallest observable path from trigger to stored state.",
        "Record findings as candidate follow-up work only after evidence exists."
      ],
      candidate_work_units: [
        %{
          title: "Trace investigation path",
          level: "task",
          desired_behavior: "Identify the source, update path, and observed failure mode.",
          testing_criteria: ["Investigation notes cite concrete code or runtime evidence."]
        },
        %{
          title: "Define validation expectation",
          level: "task",
          desired_behavior: "State how the suspected behavior should be confirmed or ruled out.",
          testing_criteria: ["Draft includes at least one executable validation expectation."]
        }
      ],
      validation_expectations: [
        "Assumptions and open questions remain explicit.",
        "Candidate work units are evidence-backed and scoped to an apply target."
      ]
    }
  },
  %{
    run_kind: "code_factory",
    artifact_type: "workflow_draft",
    template_kind: "starter_draft",
    state_machine_entrypoint: "start_code_factory_creation",
    name: "code_factory_creation",
    payload: %{
      state_machine_entrypoint: "start_code_factory_creation",
      apply_target: "workflow_bundle",
      assumptions: [
        "The factory follows work steps, eval, then route.",
        "Route steps drive transitions through structured output."
      ],
      open_questions: [
        "Which workflow should receive aligned implementation output?",
        "Which eval criteria decide whether work routes forward or loops?"
      ],
      proposed_approach: [
        "Initialize only the known Code Factory workflow bundle shape.",
        "Constrain route and eval prompts with schema-backed JSON output."
      ],
      candidate_work_units: [
        %{
          title: "Draft Code Factory workflow bundle",
          level: "ticket",
          desired_behavior:
            "Represent backlog, implementation, verification, ship, and done workflows.",
          testing_criteria: ["Each workflow has at least one structured step."]
        },
        %{
          title: "Draft route contract",
          level: "task",
          desired_behavior: "Define transition_to, transition_type, and handoff output fields.",
          testing_criteria: ["Route output schema includes required transition fields."]
        }
      ],
      validation_expectations: [
        "Route steps are not final unless they are true terminal steps.",
        "Eval and route prompts include workflow.output_schema directives."
      ]
    }
  }
]

work_breakdown_required_section_templates = [
  %{
    key: "desired_behavior",
    title: "Desired Behavior",
    required: true,
    applies_to: ["ticket", "task"],
    template: "Describe the externally visible behavior this work must deliver."
  },
  %{
    key: "testing_criteria",
    title: "Testing Criteria",
    required: true,
    applies_to: ["ticket", "task"],
    template: "List concrete checks that prove the behavior works."
  }
]

work_breakdown_supporting_record_base = %{
  run_kind: "work_breakdown",
  artifact_type: "task_draft",
  state_machine_entrypoint: "start_work_breakdown_authoring"
}

work_breakdown_supporting_records = [
  Map.merge(work_breakdown_supporting_record_base, %{
    template_kind: "section_template",
    name: "work_breakdown_authoring_sections",
    payload: %{
      scope: %{project_id: nil},
      required_sections:
        Enum.map(
          work_breakdown_required_section_templates,
          &Map.take(&1, [:key, :title, :required])
        ),
      required_section_templates: work_breakdown_required_section_templates
    }
  }),
  Map.merge(work_breakdown_supporting_record_base, %{
    template_kind: "validation_policy",
    name: "work_breakdown_authoring_validation",
    payload: %{
      scope: %{project_id: nil},
      validation_expectations: [
        "Every candidate unit has desired behavior.",
        "Every candidate unit has testing criteria.",
        "Required section templates are persisted for apply validation."
      ]
    }
  })
]

code_factory_records = [
  %{
    run_kind: "code_factory",
    artifact_type: "workflow_draft",
    template_kind: "workflow_recipe",
    state_machine_entrypoint: "start_code_factory_creation",
    name: "code_factory_workflows",
    payload: %{
      required_sections: [
        "desired_behavior",
        "constraints",
        "testing_criteria",
        "anti_patterns"
      ],
      validation_expectations: [
        "Multi-step workflows have auto_advance enabled.",
        "Route steps emit schema-constrained transition output.",
        "Route steps are not marked final."
      ],
      workflows: [
        %{
          key: "backlog",
          name: "Backlog",
          auto_advance: true,
          steps: [
            %{key: "shape", type: "work", final: false},
            %{key: "eval", type: "eval", final: false, output_schema: eval_output_schema},
            %{key: "route", type: "route", final: false, output_schema: route_output_schema}
          ]
        },
        %{
          key: "implementation",
          name: "Implementation",
          auto_advance: true,
          steps: [
            %{key: "scaffold", type: "work", final: false},
            %{key: "implement", type: "work", final: false},
            %{key: "eval", type: "eval", final: false, output_schema: eval_output_schema},
            %{
              key: "route",
              type: "route",
              final: false,
              output_schema: route_output_schema,
              transitions_to: ["implementation.implement"]
            }
          ]
        },
        %{
          key: "verification",
          name: "Verification",
          auto_advance: true,
          steps: [
            %{key: "review", type: "work", final: false},
            %{key: "eval", type: "eval", final: false, output_schema: eval_output_schema},
            %{key: "route", type: "route", final: false, output_schema: route_output_schema}
          ]
        },
        %{
          key: "ship",
          name: "Ship",
          auto_advance: true,
          steps: [
            %{key: "wait_ci", type: "work", final: false},
            %{key: "eval", type: "eval", final: false, output_schema: eval_output_schema},
            %{key: "route", type: "route", final: false, output_schema: route_output_schema}
          ]
        },
        %{
          key: "done",
          name: "Done",
          auto_advance: false,
          steps: [%{key: "complete", type: "work", final: true}]
        }
      ],
      transitions: [
        %{
          from: "implementation",
          to: "verification",
          label: "implementation_complete",
          target_step: "verification.review"
        },
        %{
          from: "verification",
          to: "implementation",
          label: "alignment_gaps",
          target_step: "implementation.implement"
        },
        %{from: "verification", to: "ship", label: "verified", target_step: "ship.wait_ci"},
        %{from: "ship", to: "done", label: "shipped", target_step: "done.complete"}
      ]
    }
  },
  %{
    run_kind: "code_factory",
    artifact_type: "workflow_draft",
    template_kind: "prompt_template",
    state_machine_entrypoint: "start_code_factory_creation",
    name: "code_factory_step_prompts",
    payload: %{
      rules: %{
        task_scope: "Use task.* fields rather than ticket.* aliases.",
        guard_variables: "Guard every optional variable or section before printing it.",
        schema_directive:
          "Eval and route prompts must ask for JSON matching workflow.output_schema."
      },
      prompts: [
        %{
          workflow: "implementation",
          step: "implement",
          requires_output_schema_directive: false,
          template: """
          Implement the requested task using the current task context.
          {% if task.desired_behavior %}Desired behavior:
          {{ task.desired_behavior }}
          {% endif %}
          {% if task.testing_criteria and task.testing_criteria.size > 0 %}Testing criteria:
          {% for t in task.testing_criteria %}- {{ t }}
          {% endfor %}{% endif %}
          """
        },
        %{
          workflow: "implementation",
          step: "eval",
          requires_output_schema_directive: true,
          template: """
          Evaluate whether the implementation satisfies task requirements.
          {% if task.constraints and task.constraints.size > 0 %}Constraints:
          {% for c in task.constraints %}- {{ c }}
          {% endfor %}{% endif %}
          {% if workflow.output_schema %}Output JSON matching:
          {{ workflow.output_schema }}{% endif %}
          """
        },
        %{
          workflow: "implementation",
          step: "route",
          requires_output_schema_directive: true,
          template: """
          Route the task based on the previous evaluation and task context.
          {% if task.desired_behavior %}Desired behavior:
          {{ task.desired_behavior }}
          {% endif %}
          {% if execution.previous_output %}Previous output:
          {{ execution.previous_output }}
          {% endif %}
          {% if workflow.output_schema %}Output JSON matching:
          {{ workflow.output_schema }}{% endif %}
          """
        }
      ]
    }
  }
]

for attrs <- starter_drafts ++ work_breakdown_supporting_records ++ code_factory_records do
  changeset = AuthoringTemplate.create_changeset(%AuthoringTemplate{}, attrs)

  Repo.insert!(
    changeset,
    on_conflict: {:replace, [:payload, :updated_at]},
    conflict_target: AuthoringTemplate.classification_fields() ++ [:name]
  )
end
