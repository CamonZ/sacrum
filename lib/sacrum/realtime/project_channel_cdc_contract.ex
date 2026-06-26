defmodule Sacrum.Realtime.ProjectChannelCdcContract do
  @moduledoc """
  Canonical default-client ProjectChannel CDC contract.

  This module describes how committed Postgres changes are projected into the
  regular GUI/CLI event stream that `SacrumWeb.ProjectChannel` pushes to
  default clients. It is intentionally separate from daemon commands:
  `run_step` and `cancel_step` are worker instructions, not GUI state
  projections, and must not be implemented by the WalEx CDC projector.

  The contract is written in terms of logical change images:

  * `after_image_fields` are read from the committed row after insert/update.
  * `before_image_fields` are read from the row image before update/delete.
  * Derived events may join persisted rows that belong to the same project.

  Healthy live CDC is incremental only. Initial snapshots and reconnect/gap
  recovery are separate contracts exposed by this module so clients do not
  treat ordinary CDC events as invalidation/refetch hints.
  """

  @daemon_event_names ["run_step", "cancel_step"]

  @entity_projection :entity_projection
  @status_projection :status_projection
  @semantic_delta :semantic_delta
  @relation_change :relation_change

  @schema_version 1

  @task_payload_keys ~w(
    id title description level priority tags rejection_reason started_at completed_at project_id workflow_id
    current_step_id parent_id status archived worktree inserted_at updated_at
  )a

  @task_event_payload_keys [:schema_version | @task_payload_keys]

  @task_deleted_payload_keys ~w(
    schema_version id current_step_id workflow_id level archived
  )a

  @task_parent_changed_payload_keys ~w(
    schema_version task_id project_id from_parent_id to_parent_id level
  )a

  @task_dependency_payload_keys ~w(
    id task_id depends_on_id project_id inserted_at updated_at
  )a

  @task_dependency_event_payload_keys [:schema_version | @task_dependency_payload_keys]

  @workflow_payload_keys ~w(
    id name description is_default is_final display_order metadata initial_step_id
    kanban_column project_id inserted_at updated_at
  )a

  @workflow_event_payload_keys [:schema_version | @workflow_payload_keys]

  @step_payload_keys ~w(
    id name goal agents skills agent_config is_final step_order step_type prompt output_schema
    verbose_daemon_logging workflow_id project_id inserted_at updated_at
  )a

  @step_event_payload_keys [:schema_version | @step_payload_keys]

  @step_transition_payload_keys ~w(
    id from_step_id to_step_id label project_id inserted_at updated_at
  )a

  @step_transition_event_payload_keys [:schema_version | @step_transition_payload_keys]

  @workflow_transition_payload_keys ~w(
    id from_workflow_id to_workflow_id target_step_id label project_id inserted_at updated_at
  )a

  @workflow_transition_event_payload_keys [:schema_version | @workflow_transition_payload_keys]

  @step_execution_payload_keys ~w(
    id task_id task_run_id workflow_id step_id project_id step_name step_type status context prompt output
    transition_result model model_provider input_tokens output_tokens cost duration_ms handoff
    session_input_tokens session_cache_read_input_tokens session_output_tokens session_total_tokens
    context_window_input_tokens context_window_cache_read_input_tokens context_window_total_tokens
    inserted_at updated_at
  )a

  @step_execution_event_payload_keys [:schema_version | @step_execution_payload_keys]

  @task_run_payload_keys ~w(
    schema_version id task_id project_id status started_at ended_at stop_requested_at
    latest_step_execution_id outcome_kind outcome_context parent_task_run_id root_task_run_id
    triggered_by_step_execution_id inserted_at updated_at run_controls
  )a

  @task_run_base_payload_keys ~w(
    id task_id project_id status started_at ended_at stop_requested_at latest_step_execution_id
    outcome_kind outcome_context parent_task_run_id root_task_run_id
    triggered_by_step_execution_id inserted_at updated_at
  )a

  @task_run_controls_payload_keys ~w(
    runnable stoppable disabled_reason_code disabled_reason active_run
  )a

  @task_run_control_source_changes [
    %{
      table: "tasks",
      operation: [:insert, :update],
      after_image_fields: [
        :id,
        :user_id,
        :project_id,
        :workflow_id,
        :current_step_id,
        :status,
        :completed_at,
        :archived
      ]
    },
    %{
      table: "step_executions",
      operation: [:insert, :update],
      after_image_fields: [:id, :task_run_id, :status]
    },
    %{
      table: "task_dependencies",
      operation: [:insert, :update, :delete],
      before_image_fields: [:task_id, :depends_on_id, :project_id],
      after_image_fields: [:task_id, :depends_on_id, :project_id]
    }
  ]

  @task_run_step_changed_payload_keys ~w(
    schema_version task_run_id task_id from_step_id to_step_id status level
  )a

  @task_step_changed_payload_keys ~w(
    schema_version task_id from_step_id to_step_id workflow_id level
  )a

  @session_log_payload_keys ~w(
    id step_execution_id project_id content format logical_key inserted_at updated_at
  )a

  @session_log_event_payload_keys [:schema_version | @session_log_payload_keys]

  @section_payload_keys ~w(
    id task_id project_id section_type content section_order done done_at inserted_at updated_at
  )a

  @section_event_payload_keys [:schema_version | @section_payload_keys]

  @code_ref_payload_keys ~w(
    id task_id section_id project_id path line_start line_end name description order_index inserted_at updated_at
  )a

  @code_ref_event_payload_keys [:schema_version | @code_ref_payload_keys]

  @contracts [
    %{
      event: "task_created",
      classification: @entity_projection,
      source_changes: [
        %{table: "tasks", operation: :insert, after_image_fields: @task_payload_keys}
      ],
      payload_keys: @task_event_payload_keys,
      schema_version: @schema_version,
      completeness:
        "Complete task row projection for list/detail stores, hierarchy placement, workflow position, archive visibility, and compatibility status."
    },
    %{
      event: "task_updated",
      classification: @entity_projection,
      source_changes: [
        %{
          table: "tasks",
          operation: :update,
          before_image_fields: [:id],
          after_image_fields: @task_payload_keys
        }
      ],
      payload_keys: @task_event_payload_keys,
      schema_version: @schema_version,
      completeness:
        "Complete task row projection; clients can upsert the task and recalculate local task buckets without fetching the task."
    },
    %{
      event: "task_deleted",
      classification: @entity_projection,
      source_changes: [
        %{
          table: "tasks",
          operation: :delete,
          before_image_fields: [
            :id,
            :project_id,
            :current_step_id,
            :workflow_id,
            :level,
            :archived
          ]
        }
      ],
      payload_keys: @task_deleted_payload_keys,
      schema_version: @schema_version,
      completeness:
        "Deletion tombstone with before-image pipeline/archive fields so clients can remove the task and decrement any affected pipeline bucket without a task-position cache."
    },
    %{
      event: "task_parent_changed",
      classification: @semantic_delta,
      source_changes: [
        %{
          table: "tasks",
          operation: :update,
          before_image_fields: [:id, :parent_id],
          after_image_fields: [:id, :project_id, :parent_id, :level]
        }
      ],
      payload_keys: @task_parent_changed_payload_keys,
      schema_version: @schema_version,
      derivation: %{
        task_id: "tasks.id",
        from_parent_id: "tasks.parent_id before image",
        to_parent_id: "tasks.parent_id after image",
        project_id: "tasks.project_id after image",
        level: "tasks.level after image",
        emission_rule: "emit only when from_parent_id != to_parent_id"
      },
      completeness:
        "Semantic hierarchy delta for tree stores. It gives clients both old and new parent ids, while task_updated carries the complete replacement task row."
    },
    %{
      event: "task_dependency_created",
      classification: @relation_change,
      source_changes: [
        %{
          table: "task_dependencies",
          operation: :insert,
          after_image_fields: @task_dependency_payload_keys
        }
      ],
      payload_keys: @task_dependency_event_payload_keys,
      schema_version: @schema_version,
      completeness:
        "Complete dependency edge projection for blocker/dependency views; clients add the edge without refetching."
    },
    %{
      event: "task_dependency_deleted",
      classification: @relation_change,
      source_changes: [
        %{
          table: "task_dependencies",
          operation: :delete,
          before_image_fields: @task_dependency_payload_keys
        }
      ],
      payload_keys: @task_dependency_event_payload_keys,
      schema_version: @schema_version,
      completeness:
        "Complete dependency edge tombstone from the before image so clients can remove by id or task/blocker endpoints without refetching."
    },
    %{
      event: "workflow_created",
      classification: @entity_projection,
      source_changes: [
        %{table: "workflows", operation: :insert, after_image_fields: @workflow_payload_keys}
      ],
      payload_keys: @workflow_event_payload_keys,
      schema_version: @schema_version,
      completeness: "Complete workflow projection for workflow and pipeline graph stores."
    },
    %{
      event: "workflow_updated",
      classification: @entity_projection,
      source_changes: [
        %{
          table: "workflows",
          operation: :update,
          before_image_fields: [:id],
          after_image_fields: @workflow_payload_keys
        }
      ],
      payload_keys: @workflow_event_payload_keys,
      schema_version: @schema_version,
      completeness: "Complete workflow projection for in-place graph/list updates."
    },
    %{
      event: "workflow_deleted",
      classification: @entity_projection,
      source_changes: [
        %{table: "workflows", operation: :delete, before_image_fields: [:id, :project_id]}
      ],
      payload_keys: [:schema_version, :id],
      schema_version: @schema_version,
      completeness: "Deletion tombstone; clients remove the workflow by id."
    },
    %{
      event: "step_created",
      classification: @entity_projection,
      source_changes: [
        %{
          table: "workflow_steps",
          operation: :insert,
          after_image_fields: @step_payload_keys
        }
      ],
      payload_keys: @step_event_payload_keys,
      schema_version: @schema_version,
      completeness:
        "Complete workflow step projection, including prompt/schema fields needed by workflow editors and human-input displays."
    },
    %{
      event: "step_updated",
      classification: @entity_projection,
      source_changes: [
        %{
          table: "workflow_steps",
          operation: :update,
          before_image_fields: [:id],
          after_image_fields: @step_payload_keys
        }
      ],
      payload_keys: @step_event_payload_keys,
      schema_version: @schema_version,
      completeness: "Complete workflow step projection for in-place graph/editor updates."
    },
    %{
      event: "step_deleted",
      classification: @entity_projection,
      source_changes: [
        %{
          table: "workflow_steps",
          operation: :delete,
          before_image_fields: [:id, :workflow_id, :project_id]
        }
      ],
      payload_keys: [:schema_version, :id, :workflow_id],
      schema_version: @schema_version,
      completeness:
        "Deletion tombstone with workflow scope so clients can remove the step from the correct graph."
    },
    %{
      event: "step_transition_created",
      classification: @relation_change,
      source_changes: [
        %{
          table: "step_transitions",
          operation: :insert,
          after_image_fields: @step_transition_payload_keys
        }
      ],
      payload_keys: @step_transition_event_payload_keys,
      schema_version: @schema_version,
      completeness: "Complete step-edge projection for pipeline graph updates."
    },
    %{
      event: "step_transition_deleted",
      classification: @relation_change,
      source_changes: [
        %{
          table: "step_transitions",
          operation: :delete,
          before_image_fields: @step_transition_payload_keys
        }
      ],
      payload_keys: @step_transition_event_payload_keys,
      schema_version: @schema_version,
      completeness:
        "Complete relation tombstone from the before image, allowing clients to remove by id or endpoints without a step-transition cache."
    },
    %{
      event: "workflow_transition_created",
      classification: @relation_change,
      source_changes: [
        %{
          table: "workflow_transitions",
          operation: :insert,
          after_image_fields: @workflow_transition_payload_keys
        }
      ],
      payload_keys: @workflow_transition_event_payload_keys,
      schema_version: @schema_version,
      completeness: "Complete workflow-edge projection for graph updates."
    },
    %{
      event: "workflow_transition_deleted",
      classification: @relation_change,
      source_changes: [
        %{
          table: "workflow_transitions",
          operation: :delete,
          before_image_fields: @workflow_transition_payload_keys
        }
      ],
      payload_keys: @workflow_transition_event_payload_keys,
      schema_version: @schema_version,
      completeness:
        "Complete workflow-edge tombstone so clients can remove by id or by edge endpoints."
    },
    %{
      event: "step_execution_created",
      classification: @entity_projection,
      source_changes: [
        %{
          table: "step_executions",
          operation: :insert,
          after_image_fields: @step_execution_payload_keys
        }
      ],
      payload_keys: @step_execution_event_payload_keys,
      schema_version: @schema_version,
      completeness:
        "Complete attempt projection for execution history and latest-attempt UI; not a pipeline movement signal."
    },
    %{
      event: "step_execution_status_changed",
      classification: @status_projection,
      source_changes: [
        %{
          table: "step_executions",
          operation: :update,
          before_image_fields: [:id, :status],
          after_image_fields: @step_execution_payload_keys
        }
      ],
      payload_keys: @step_execution_event_payload_keys,
      schema_version: @schema_version,
      completeness:
        "Complete attempt status projection; clients update execution history without inferring TaskRun terminal state."
    },
    %{
      event: "task_run_created",
      classification: @entity_projection,
      source_changes: [
        %{table: "task_runs", operation: :insert, after_image_fields: @task_run_base_payload_keys}
        | @task_run_control_source_changes
      ],
      payload_keys: @task_run_payload_keys,
      nested_payload_keys: %{
        run_controls: @task_run_controls_payload_keys,
        "run_controls.active_run": @task_run_base_payload_keys
      },
      schema_version: @schema_version,
      derivation: %{
        run_controls:
          "server-side enrichment computed through Sacrum.TaskRuns.RunControls from the TaskRun after image, owning task row, direct blocker rows, latest step execution, and TaskRegistry process state; it is not a pure task_runs row projection"
      },
      completeness:
        "Complete run projection plus server-derived run controls for row controls and active-run state."
    },
    %{
      event: "task_run_updated",
      classification: @status_projection,
      source_changes: [
        %{
          table: "task_runs",
          operation: :update,
          before_image_fields: [:id, :status, :latest_step_execution_id],
          after_image_fields: @task_run_base_payload_keys
        }
        | @task_run_control_source_changes
      ],
      payload_keys: @task_run_payload_keys,
      nested_payload_keys: %{
        run_controls: @task_run_controls_payload_keys,
        "run_controls.active_run": @task_run_base_payload_keys
      },
      schema_version: @schema_version,
      derivation: %{
        run_controls:
          "server-side enrichment computed through Sacrum.TaskRuns.RunControls from the TaskRun after image, owning task row, direct blocker rows, latest step execution, and TaskRegistry process state; it is not a pure task_runs row projection"
      },
      completeness:
        "Complete run projection plus replacement run controls; clients must prefer this over local control recomputation."
    },
    %{
      event: "task_run_step_changed",
      classification: @semantic_delta,
      source_changes: [
        %{
          table: "tasks",
          operation: :update,
          before_image_fields: [:id, :current_step_id],
          after_image_fields: [:id, :project_id, :current_step_id, :level]
        },
        %{
          table: "task_runs",
          operation: [:insert, :update],
          before_image_fields: [:id, :status],
          after_image_fields: [:id, :task_id, :project_id, :status]
        }
      ],
      payload_keys: @task_run_step_changed_payload_keys,
      schema_version: @schema_version,
      derivation: %{
        task_run_id: "task_runs.id",
        task_id: "tasks.id",
        from_step_id:
          "tasks.current_step_id before image for movement; tasks.current_step_id after image for run-end events",
        to_step_id:
          "tasks.current_step_id after image for movement; nil when task_runs.status leaves active statuses at run end",
        status: "task_runs.status after image encoded with Sacrum.TaskRuns.Status.wire_value/1",
        level: "tasks.level after image",
        run_start_rule:
          "emit task_run_step_changed once immediately after task_run_created for each newly created root or child TaskRun, with from_step_id nil and to_step_id set to the task's current_step_id, before the first task_run_updated/dispatch event"
      },
      completeness:
        "Semantic movement delta for active pipeline buckets. It is derived from persisted task/task_run rows and carries all values needed to move counts."
    },
    %{
      event: "task_step_changed",
      classification: @semantic_delta,
      source_changes: [
        %{
          table: "tasks",
          operation: :update,
          before_image_fields: [:id, :current_step_id],
          after_image_fields: [:id, :project_id, :workflow_id, :current_step_id, :level]
        }
      ],
      payload_keys: @task_step_changed_payload_keys,
      schema_version: @schema_version,
      derivation: %{
        task_id: "tasks.id",
        from_step_id: "tasks.current_step_id before image",
        to_step_id: "tasks.current_step_id after image",
        workflow_id: "tasks.workflow_id after image",
        level: "tasks.level after image",
        emission_rule:
          "emit only when from_step_id != to_step_id and no active orchestrator/TaskRun owns the move"
      },
      completeness:
        "Semantic manual movement delta for pipeline buckets. No task_run_id/status is included because no TaskRun owns manual moves."
    },
    %{
      event: "session_log_created",
      classification: @entity_projection,
      source_changes: [
        %{
          table: "session_logs",
          operation: :insert,
          after_image_fields: @session_log_payload_keys
        }
      ],
      payload_keys: @session_log_event_payload_keys,
      schema_version: @schema_version,
      completeness:
        "Complete log projection keyed by step_execution_id; clients append this event."
    },
    %{
      event: "session_log_updated",
      classification: @entity_projection,
      source_changes: [
        %{
          table: "session_logs",
          operation: :update,
          after_image_fields: @session_log_payload_keys
        }
      ],
      payload_keys: @session_log_event_payload_keys,
      schema_version: @schema_version,
      completeness:
        "Complete logical-key log projection keyed by id and step_execution_id; clients replace the existing log row."
    },
    %{
      event: "section_created",
      classification: @entity_projection,
      source_changes: [
        %{table: "task_sections", operation: :insert, after_image_fields: @section_payload_keys}
      ],
      payload_keys: @section_event_payload_keys,
      schema_version: @schema_version,
      completeness: "Complete section projection for task detail/checklist stores."
    },
    %{
      event: "section_updated",
      classification: @entity_projection,
      source_changes: [
        %{
          table: "task_sections",
          operation: :update,
          before_image_fields: [:id],
          after_image_fields: @section_payload_keys
        }
      ],
      payload_keys: @section_event_payload_keys,
      schema_version: @schema_version,
      completeness: "Complete section projection for task detail/checklist stores."
    },
    %{
      event: "section_deleted",
      classification: @entity_projection,
      source_changes: [
        %{
          table: "task_sections",
          operation: :delete,
          before_image_fields: [:id, :task_id, :project_id]
        }
      ],
      payload_keys: [:schema_version, :id, :task_id],
      schema_version: @schema_version,
      completeness: "Deletion tombstone with task scope so clients can remove the section by id."
    },
    %{
      event: "code_ref_created",
      classification: @relation_change,
      source_changes: [
        %{table: "code_refs", operation: :insert, after_image_fields: @code_ref_payload_keys}
      ],
      payload_keys: @code_ref_event_payload_keys,
      schema_version: @schema_version,
      completeness:
        "Complete code reference projection for task detail, section detail, and evidence views; clients add the reference without refetching."
    },
    %{
      event: "code_ref_updated",
      classification: @relation_change,
      source_changes: [
        %{
          table: "code_refs",
          operation: :update,
          before_image_fields: [:id],
          after_image_fields: @code_ref_payload_keys
        }
      ],
      payload_keys: @code_ref_event_payload_keys,
      schema_version: @schema_version,
      completeness:
        "Complete code reference replacement for task detail, section detail, and evidence views."
    },
    %{
      event: "code_ref_deleted",
      classification: @relation_change,
      source_changes: [
        %{table: "code_refs", operation: :delete, before_image_fields: @code_ref_payload_keys}
      ],
      payload_keys: @code_ref_event_payload_keys,
      schema_version: @schema_version,
      completeness:
        "Complete code reference tombstone from the before image so clients can remove by id without refetching."
    }
  ]

  @initial_snapshot_contract %{
    purpose: "Build a complete GUI store before applying live CDC events.",
    mode: :snapshot_then_stream,
    required_scope: [:project_id, :user_id],
    cursor_rule:
      "Capture a CDC cursor/LSN for the snapshot boundary, read all project rows at or before that boundary, then apply committed WalEx changes after that cursor in commit order.",
    source_tables: ~w(
      projects workflows workflow_steps step_transitions workflow_transitions tasks task_runs
      step_executions session_logs task_sections task_dependencies code_refs
    ),
    gui_projection:
      "Equivalent to the GraphQL task list/detail, pipeline summary, run trace, and section queries for the project. Include archived tasks when building a full local store."
  }

  @reconnect_gap_recovery_contract %{
    healthy_reconnect:
      "If the client's last acknowledged CDC cursor is still retained, replay changes after that cursor in commit order and de-duplicate by event name plus primary key/update timestamp where needed.",
    gap_detected:
      "If the cursor is missing, out of retention, or sequence continuity is uncertain, discard speculative incremental counts, rerun the initial snapshot contract, and resume from the new snapshot cursor.",
    client_rule:
      "Routine live CDC events are projections, not invalidation signals. Refetch is reserved for initial load and explicit gap recovery."
  }

  @event_names Enum.map(@contracts, & &1.event)

  @spec daemon_event_names() :: [String.t()]
  def daemon_event_names, do: @daemon_event_names

  @spec regular_event_names() :: [String.t()]
  def regular_event_names, do: @event_names

  @spec intercepted_event_names() :: [String.t()]
  def intercepted_event_names, do: @event_names ++ @daemon_event_names

  @spec contracts() :: [map()]
  def contracts, do: @contracts

  @spec contract_for(String.t()) :: {:ok, map()} | {:error, :daemon_event | :unknown_event}
  def contract_for(event) when event in @daemon_event_names, do: {:error, :daemon_event}

  def contract_for(event) when is_binary(event) do
    case Enum.find(@contracts, &(&1.event == event)) do
      nil -> {:error, :unknown_event}
      contract -> {:ok, contract}
    end
  end

  @spec regular_event?(String.t()) :: boolean()
  def regular_event?(event), do: event in @event_names

  @spec daemon_event?(String.t()) :: boolean()
  def daemon_event?(event), do: event in @daemon_event_names

  @spec initial_snapshot_contract() :: map()
  def initial_snapshot_contract, do: @initial_snapshot_contract

  @spec reconnect_gap_recovery_contract() :: map()
  def reconnect_gap_recovery_contract, do: @reconnect_gap_recovery_contract
end
