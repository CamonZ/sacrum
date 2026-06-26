defmodule Sacrum.Realtime.ProjectChannelCdcContractTest do
  use ExUnit.Case, async: true

  alias Sacrum.Realtime.ProjectChannelCdcContract
  alias SacrumWeb.ProjectChannel

  @classifications [
    :entity_projection,
    :status_projection,
    :semantic_delta,
    :relation_change
  ]

  test "covers every runtime non-daemon ProjectChannel event" do
    daemon_events = ProjectChannel.daemon_event_names()
    non_daemon_events = runtime_channel_event_names() -- daemon_events

    assert Enum.sort(ProjectChannelCdcContract.regular_event_names()) ==
             Enum.sort(non_daemon_events)

    intercepted_events = ProjectChannel.intercepted_event_names()
    assert Enum.sort(intercepted_events) == Enum.sort(runtime_channel_event_names())
    assert length(intercepted_events) == length(Enum.uniq(intercepted_events))

    for event <- non_daemon_events do
      assert {:ok, %{event: ^event}} = ProjectChannelCdcContract.contract_for(event)
    end
  end

  test "excludes daemon command events from the regular-client CDC mapper" do
    for event <- ["run_step", "cancel_step"] do
      refute event in ProjectChannelCdcContract.regular_event_names()
      assert ProjectChannelCdcContract.daemon_event?(event)
      assert {:error, :daemon_event} = ProjectChannelCdcContract.contract_for(event)
    end
  end

  test "each regular event declares source rows, change images, projection keys, and completeness" do
    for contract <- ProjectChannelCdcContract.contracts() do
      assert contract.classification in @classifications
      assert is_binary(contract.completeness)
      assert contract.completeness != ""
      assert contract.schema_version == 1
      assert is_list(contract.payload_keys)
      assert contract.payload_keys != []
      assert :schema_version in contract.payload_keys
      assert is_list(contract.source_changes)
      assert contract.source_changes != []

      for source_change <- contract.source_changes do
        assert is_binary(source_change.table)
        assert source_change.table != ""
        assert Map.has_key?(source_change, :operation)

        assert Map.has_key?(source_change, :before_image_fields) or
                 Map.has_key?(source_change, :after_image_fields)

        refute :schema_version in Map.get(source_change, :before_image_fields, [])
        refute :schema_version in Map.get(source_change, :after_image_fields, [])
      end
    end
  end

  test "derived step movement events are explicit about current_step_id before and after images" do
    assert {:ok, task_run_contract} =
             ProjectChannelCdcContract.contract_for("task_run_step_changed")

    assert task_run_contract.classification == :semantic_delta
    assert source_tables(task_run_contract) == MapSet.new(["tasks", "task_runs"])

    task_run_task_source = source_change(task_run_contract, "tasks")
    assert :current_step_id in task_run_task_source.before_image_fields
    assert :current_step_id in task_run_task_source.after_image_fields
    assert task_run_contract.derivation.from_step_id =~ "before image"
    assert task_run_contract.derivation.to_step_id =~ "nil when task_runs.status leaves active"
    assert task_run_contract.derivation.status =~ "task_runs.status after image"

    assert {:ok, task_contract} = ProjectChannelCdcContract.contract_for("task_step_changed")
    assert task_contract.classification == :semantic_delta
    assert source_tables(task_contract) == MapSet.new(["tasks"])

    task_source = source_change(task_contract, "tasks")
    assert :current_step_id in task_source.before_image_fields
    assert :current_step_id in task_source.after_image_fields
    assert task_contract.derivation.emission_rule =~ "from_step_id != to_step_id"
    assert task_contract.derivation.emission_rule =~ "no active orchestrator/TaskRun"
  end

  test "hierarchy and relation gap events are explicit CDC projections" do
    assert {:ok, parent_contract} = ProjectChannelCdcContract.contract_for("task_parent_changed")
    assert parent_contract.classification == :semantic_delta

    parent_source = source_change(parent_contract, "tasks")
    assert :parent_id in parent_source.before_image_fields
    assert :parent_id in parent_source.after_image_fields
    assert parent_contract.derivation.from_parent_id =~ "before image"
    assert parent_contract.derivation.to_parent_id =~ "after image"

    assert {:ok, dependency_contract} =
             ProjectChannelCdcContract.contract_for("task_dependency_created")

    assert dependency_contract.classification == :relation_change
    assert source_tables(dependency_contract) == MapSet.new(["task_dependencies"])

    assert {:ok, code_ref_contract} = ProjectChannelCdcContract.contract_for("code_ref_deleted")
    assert code_ref_contract.classification == :relation_change
    assert source_tables(code_ref_contract) == MapSet.new(["code_refs"])
    assert code_ref_contract.completeness =~ "without refetching"
  end

  test "representative payload contracts are complete for GUI store updates" do
    assert_payload_includes("task_updated", [
      :schema_version,
      :id,
      :title,
      :project_id,
      :workflow_id,
      :current_step_id,
      :parent_id,
      :status,
      :archived,
      :updated_at
    ])

    assert_payload_excludes("task_updated", [
      :needs_human_review,
      :review_comment,
      :revision_feedback
    ])

    assert_payload_includes("task_deleted", [
      :schema_version,
      :id,
      :current_step_id,
      :workflow_id,
      :level,
      :archived
    ])

    assert_payload_includes("task_parent_changed", [
      :schema_version,
      :task_id,
      :project_id,
      :from_parent_id,
      :to_parent_id,
      :level
    ])

    assert_payload_includes("task_dependency_created", [
      :schema_version,
      :id,
      :task_id,
      :depends_on_id,
      :project_id,
      :inserted_at,
      :updated_at
    ])

    assert_payload_includes("task_dependency_deleted", [
      :schema_version,
      :id,
      :task_id,
      :depends_on_id,
      :project_id,
      :inserted_at,
      :updated_at
    ])

    assert_payload_includes("step_updated", [
      :schema_version,
      :id,
      :workflow_id,
      :project_id,
      :step_type,
      :prompt,
      :output_schema,
      :verbose_daemon_logging,
      :updated_at
    ])

    assert_payload_includes("step_transition_deleted", [
      :schema_version,
      :id,
      :from_step_id,
      :to_step_id
    ])

    assert_payload_includes("task_run_updated", [
      :schema_version,
      :id,
      :task_id,
      :project_id,
      :status,
      :latest_step_execution_id,
      :outcome_kind,
      :outcome_context,
      :run_controls,
      :updated_at
    ])

    assert_payload_includes("step_execution_status_changed", [
      :schema_version,
      :id,
      :task_id,
      :task_run_id,
      :workflow_id,
      :step_id,
      :project_id,
      :step_type,
      :status,
      :handoff,
      :updated_at
    ])

    session_log_payload_keys = [
      :schema_version,
      :id,
      :step_execution_id,
      :project_id,
      :content,
      :format,
      :logical_key,
      :inserted_at,
      :updated_at
    ]

    assert_payload_includes("session_log_created", session_log_payload_keys)
    assert_payload_includes("session_log_updated", session_log_payload_keys)

    assert_payload_includes("code_ref_created", [
      :schema_version,
      :id,
      :task_id,
      :section_id,
      :project_id,
      :path,
      :line_start,
      :line_end,
      :name,
      :description,
      :order_index
    ])

    assert_payload_includes("code_ref_updated", [
      :schema_version,
      :id,
      :task_id,
      :section_id,
      :project_id,
      :path,
      :line_start,
      :line_end,
      :name,
      :description,
      :order_index
    ])

    assert_payload_includes("code_ref_deleted", [
      :schema_version,
      :id,
      :task_id,
      :section_id,
      :project_id,
      :path,
      :line_start,
      :line_end,
      :name,
      :description,
      :order_index
    ])

    assert_payload_includes("task_run_step_changed", [
      :schema_version,
      :task_run_id,
      :task_id,
      :from_step_id,
      :to_step_id,
      :status,
      :level
    ])

    assert_payload_includes("task_step_changed", [
      :schema_version,
      :task_id,
      :from_step_id,
      :to_step_id,
      :workflow_id,
      :level
    ])
  end

  test "snapshot and gap recovery are separate from healthy live CDC" do
    snapshot = ProjectChannelCdcContract.initial_snapshot_contract()
    recovery = ProjectChannelCdcContract.reconnect_gap_recovery_contract()

    assert snapshot.mode == :snapshot_then_stream
    assert snapshot.cursor_rule =~ "snapshot boundary"
    assert "tasks" in snapshot.source_tables
    assert "task_runs" in snapshot.source_tables
    assert "task_dependencies" in snapshot.source_tables
    assert "code_refs" in snapshot.source_tables

    assert recovery.healthy_reconnect =~ "replay changes"
    assert recovery.gap_detected =~ "rerun the initial snapshot"
    assert recovery.client_rule =~ "not invalidation signals"
  end

  defp assert_payload_includes(event, expected_keys) do
    assert {:ok, contract} = ProjectChannelCdcContract.contract_for(event)

    missing_keys =
      expected_keys
      |> MapSet.new()
      |> MapSet.difference(MapSet.new(contract.payload_keys))
      |> MapSet.to_list()

    assert missing_keys == []
  end

  defp assert_payload_excludes(event, removed_keys) do
    assert {:ok, contract} = ProjectChannelCdcContract.contract_for(event)

    present_keys =
      removed_keys
      |> MapSet.new()
      |> MapSet.intersection(MapSet.new(contract.payload_keys))
      |> MapSet.to_list()

    assert present_keys == []
  end

  defp source_tables(contract) do
    contract.source_changes
    |> Enum.map(& &1.table)
    |> MapSet.new()
  end

  defp source_change(contract, table) do
    Enum.find(contract.source_changes, &(&1.table == table))
  end

  defp runtime_channel_event_names do
    ProjectChannel.__info__(:functions)
    |> Enum.map(&elem(&1, 0))
    |> Enum.filter(&String.starts_with?(Atom.to_string(&1), "broadcast_"))
    |> Enum.map(&String.replace_prefix(Atom.to_string(&1), "broadcast_", ""))
  end
end
