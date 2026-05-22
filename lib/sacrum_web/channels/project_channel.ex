defmodule SacrumWeb.ProjectChannel do
  use Phoenix.Channel

  alias Sacrum.Accounts.Projects
  alias Sacrum.Chat.PublicEvents
  alias Sacrum.Realtime.ProjectChannelCdcContract
  alias Sacrum.TaskRuns.RunControls
  alias Sacrum.TaskRuns.Status, as: TaskRunStatus

  @valid_client_types ~w(default daemon)
  @daemon_events ProjectChannelCdcContract.daemon_event_names()
  @default_events ProjectChannelCdcContract.regular_event_names()
  @schema_version 1

  intercept(@default_events ++ @daemon_events)

  @spec default_client_event_names() :: [String.t()]
  def default_client_event_names, do: @default_events

  @spec daemon_event_names() :: [String.t()]
  def daemon_event_names, do: @daemon_events

  @spec intercepted_event_names() :: [String.t()]
  def intercepted_event_names, do: @default_events ++ @daemon_events

  @impl true
  def join("project:" <> project_id, params, socket) do
    user = socket.assigns.current_user
    client_type = validate_client_type(params)

    case Projects.get_by(user.id, conditions: [id: project_id]) do
      {:ok, project} ->
        # Register daemon with the DaemonRegistry if client_type is daemon
        if client_type == "daemon" do
          Sacrum.DaemonRegistry.register_daemon(project_id)
        end

        {:ok, socket |> assign(:project, project) |> assign(:client_type, client_type)}

      {:error, :not_found} ->
        {:error, %{reason: "not found"}}
    end
  end

  defp validate_client_type(params) do
    client_type = Map.get(params, "client_type", "default")
    if client_type in @valid_client_types, do: client_type, else: "default"
  end

  @impl true
  def terminate(_reason, socket) do
    # Unregister daemon when it disconnects
    if Map.get(socket.assigns, :client_type) == "daemon" do
      project_id = socket.assigns.project.id
      Sacrum.DaemonRegistry.unregister_daemon(project_id)
    end

    :ok
  end

  @impl true
  def handle_out(event, payload, socket) do
    if should_push?(socket.assigns.client_type, event) do
      push(socket, event, payload)
    end

    {:noreply, socket}
  end

  defp should_push?(client_type, event) do
    case client_type do
      "default" -> event not in @daemon_events
      "daemon" -> event in @daemon_events
      _ -> false
    end
  end

  # Task broadcasts

  @spec broadcast_task_created(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_task_created(project_id, task) do
    SacrumWeb.Endpoint.broadcast("project:#{project_id}", "task_created", task_payload(task))
  end

  @spec broadcast_task_updated(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_task_updated(project_id, task) do
    SacrumWeb.Endpoint.broadcast("project:#{project_id}", "task_updated", task_payload(task))
  end

  @spec broadcast_task_deleted(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_task_deleted(project_id, task) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "task_deleted",
      task_deleted_payload(task)
    )
  end

  @spec broadcast_task_parent_changed(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_task_parent_changed(project_id, payload) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "task_parent_changed",
      task_parent_changed_payload(payload)
    )
  end

  # Task dependency broadcasts

  @spec broadcast_task_dependency_created(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_task_dependency_created(project_id, dependency) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "task_dependency_created",
      task_dependency_payload(dependency)
    )
  end

  @spec broadcast_task_dependency_deleted(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_task_dependency_deleted(project_id, dependency) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "task_dependency_deleted",
      task_dependency_payload(dependency)
    )
  end

  # Workflow broadcasts

  @spec broadcast_workflow_created(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_workflow_created(project_id, workflow) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "workflow_created",
      workflow_entity_payload(workflow)
    )
  end

  @spec broadcast_workflow_updated(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_workflow_updated(project_id, workflow) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "workflow_updated",
      workflow_entity_payload(workflow)
    )
  end

  @spec broadcast_workflow_deleted(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_workflow_deleted(project_id, workflow) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "workflow_deleted",
      version_payload(%{id: workflow.id})
    )
  end

  # Step broadcasts

  @spec broadcast_step_created(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_step_created(project_id, step) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "step_created",
      step_payload(step)
    )
  end

  @spec broadcast_step_updated(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_step_updated(project_id, step) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "step_updated",
      step_payload(step)
    )
  end

  @spec broadcast_step_deleted(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_step_deleted(project_id, step) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "step_deleted",
      version_payload(%{id: step.id, workflow_id: step.workflow_id})
    )
  end

  # Step transition broadcasts

  @spec broadcast_step_transition_created(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_step_transition_created(project_id, transition) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "step_transition_created",
      step_transition_payload(transition)
    )
  end

  @spec broadcast_step_transition_deleted(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_step_transition_deleted(project_id, transition) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "step_transition_deleted",
      step_transition_payload(transition)
    )
  end

  # Workflow transition broadcasts

  @spec broadcast_workflow_transition_created(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_workflow_transition_created(project_id, transition) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "workflow_transition_created",
      workflow_transition_payload(transition)
    )
  end

  @spec broadcast_workflow_transition_deleted(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_workflow_transition_deleted(project_id, transition) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "workflow_transition_deleted",
      workflow_transition_payload(transition)
    )
  end

  # Step execution broadcasts

  @spec broadcast_step_execution_created(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_step_execution_created(project_id, execution) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "step_execution_created",
      step_execution_payload(execution)
    )
  end

  @spec broadcast_step_execution_status_changed(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_step_execution_status_changed(project_id, execution) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "step_execution_status_changed",
      step_execution_payload(execution)
    )
  end

  # TaskRun broadcasts

  @spec broadcast_task_run_created(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_task_run_created(project_id, task_run) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "task_run_created",
      task_run_payload(task_run)
    )
  end

  @spec broadcast_task_run_updated(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_task_run_updated(project_id, task_run) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "task_run_updated",
      task_run_payload(task_run)
    )
  end

  @spec broadcast_task_run_step_changed(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_task_run_step_changed(project_id, payload) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "task_run_step_changed",
      task_run_step_changed_payload(payload)
    )
  end

  @spec broadcast_task_step_changed(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_task_step_changed(project_id, payload) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "task_step_changed",
      task_step_changed_payload(payload)
    )
  end

  # Daemon broadcasts

  @spec broadcast_run_step(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_run_step(project_id, data) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "run_step",
      run_step_payload(data)
    )
  end

  @spec broadcast_cancel_step(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_cancel_step(project_id, data) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "cancel_step",
      cancel_step_payload(data)
    )
  end

  # Session log broadcasts

  @spec broadcast_session_log_created(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_session_log_created(project_id, log) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "session_log_created",
      session_log_payload(log)
    )
  end

  # Chat broadcasts

  @spec broadcast_chat_event(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_chat_event(project_id, chat_event) do
    case PublicEvents.channel_event(chat_event) do
      {:ok, event, payload} ->
        SacrumWeb.Endpoint.broadcast("project:#{project_id}", event, version_payload(payload))

      :ignore ->
        :ok
    end
  end

  # Section broadcasts

  @spec broadcast_section_created(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_section_created(project_id, section) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "section_created",
      section_payload(section)
    )
  end

  @spec broadcast_section_updated(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_section_updated(project_id, section) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "section_updated",
      section_payload(section)
    )
  end

  @spec broadcast_section_deleted(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_section_deleted(project_id, section) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "section_deleted",
      version_payload(%{id: section.id, task_id: section.task_id})
    )
  end

  # Code ref broadcasts

  @spec broadcast_code_ref_created(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_code_ref_created(project_id, code_ref) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "code_ref_created",
      code_ref_payload(code_ref)
    )
  end

  @spec broadcast_code_ref_updated(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_code_ref_updated(project_id, code_ref) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "code_ref_updated",
      code_ref_payload(code_ref)
    )
  end

  @spec broadcast_code_ref_deleted(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_code_ref_deleted(project_id, code_ref) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "code_ref_deleted",
      code_ref_payload(code_ref)
    )
  end

  # Payload helpers

  defp version_payload(payload), do: Map.put(payload, :schema_version, @schema_version)

  defp task_payload(task) do
    version_payload(%{
      id: task.id,
      short_id: task.short_id,
      title: task.title,
      description: task.description,
      level: task.level,
      priority: task.priority,
      tags: task.tags,
      needs_human_review: task.needs_human_review,
      review_comment: task.review_comment,
      rejection_reason: task.rejection_reason,
      revision_feedback: task.revision_feedback,
      started_at: task.started_at,
      completed_at: task.completed_at,
      project_id: task.project_id,
      workflow_id: task.workflow_id,
      current_step_id: task.current_step_id,
      parent_id: task.parent_id,
      status: task.status,
      archived: task.archived,
      worktree: task.worktree,
      inserted_at: task.inserted_at,
      updated_at: task.updated_at
    })
  end

  defp task_deleted_payload(task) do
    version_payload(%{
      id: task.id,
      current_step_id: task.current_step_id,
      workflow_id: task.workflow_id,
      level: task.level,
      archived: task.archived
    })
  end

  defp task_parent_changed_payload(%{
         task_id: task_id,
         project_id: project_id,
         from_parent_id: from_parent_id,
         to_parent_id: to_parent_id,
         level: level
       }) do
    version_payload(%{
      task_id: task_id,
      project_id: project_id,
      from_parent_id: from_parent_id,
      to_parent_id: to_parent_id,
      level: level
    })
  end

  defp task_dependency_payload(dependency) do
    version_payload(%{
      id: dependency.id,
      task_id: dependency.task_id,
      depends_on_id: dependency.depends_on_id,
      project_id: dependency.project_id,
      inserted_at: dependency.inserted_at,
      updated_at: dependency.updated_at
    })
  end

  defp task_run_step_changed_payload(%{
         task_run_id: task_run_id,
         task_id: task_id,
         from_step_id: from_step_id,
         to_step_id: to_step_id,
         status: status,
         level: level
       }) do
    version_payload(%{
      task_run_id: task_run_id,
      task_id: task_id,
      from_step_id: from_step_id,
      to_step_id: to_step_id,
      status: TaskRunStatus.wire_value(status),
      level: level
    })
  end

  defp task_step_changed_payload(%{
         task_id: task_id,
         from_step_id: from_step_id,
         to_step_id: to_step_id,
         workflow_id: workflow_id,
         level: level
       }) do
    version_payload(%{
      task_id: task_id,
      from_step_id: from_step_id,
      to_step_id: to_step_id,
      workflow_id: workflow_id,
      level: level
    })
  end

  defp workflow_entity_payload(workflow) do
    version_payload(%{
      id: workflow.id,
      name: workflow.name,
      description: workflow.description,
      is_default: workflow.is_default,
      is_final: workflow.is_final,
      display_order: workflow.display_order,
      metadata: workflow.metadata,
      initial_step_id: workflow.initial_step_id,
      kanban_column: workflow.kanban_column,
      project_id: workflow.project_id,
      inserted_at: workflow.inserted_at,
      updated_at: workflow.updated_at
    })
  end

  defp step_payload(step) do
    version_payload(%{
      id: step.id,
      name: step.name,
      goal: step.goal,
      agents: step.agents,
      skills: step.skills,
      agent_config: step.agent_config,
      is_final: step.is_final,
      step_order: step.step_order,
      step_type: step.step_type,
      prompt: step.prompt,
      output_schema: step.output_schema,
      verbose_daemon_logging: step.verbose_daemon_logging,
      workflow_id: step.workflow_id,
      project_id: step.project_id,
      inserted_at: step.inserted_at,
      updated_at: step.updated_at
    })
  end

  defp step_transition_payload(transition) do
    version_payload(%{
      id: transition.id,
      from_step_id: transition.from_step_id,
      to_step_id: transition.to_step_id,
      label: transition.label,
      project_id: transition.project_id,
      inserted_at: transition.inserted_at,
      updated_at: transition.updated_at
    })
  end

  defp workflow_transition_payload(transition) do
    version_payload(%{
      id: transition.id,
      from_workflow_id: transition.from_workflow_id,
      to_workflow_id: transition.to_workflow_id,
      target_step_id: transition.target_step_id,
      label: transition.label,
      project_id: transition.project_id,
      inserted_at: transition.inserted_at,
      updated_at: transition.updated_at
    })
  end

  defp step_execution_payload(execution) do
    version_payload(%{
      id: field_value(execution, :id),
      task_id: field_value(execution, :task_id),
      task_run_id: field_value(execution, :task_run_id),
      workflow_id: field_value(execution, :workflow_id),
      step_id: field_value(execution, :step_id),
      project_id: field_value(execution, :project_id),
      step_name: field_value(execution, :step_name),
      step_type: field_value(execution, :step_type),
      status: field_value(execution, :status),
      context: field_value(execution, :context),
      prompt: field_value(execution, :prompt),
      output: field_value(execution, :output),
      transition_result: field_value(execution, :transition_result),
      model: field_value(execution, :model),
      model_provider: field_value(execution, :model_provider),
      input_tokens: field_value(execution, :input_tokens),
      output_tokens: field_value(execution, :output_tokens),
      session_input_tokens: field_value(execution, :session_input_tokens),
      session_cache_read_input_tokens: field_value(execution, :session_cache_read_input_tokens),
      session_output_tokens: field_value(execution, :session_output_tokens),
      session_total_tokens: field_value(execution, :session_total_tokens),
      context_window_input_tokens: field_value(execution, :context_window_input_tokens),
      context_window_cache_read_input_tokens:
        field_value(execution, :context_window_cache_read_input_tokens),
      context_window_total_tokens: field_value(execution, :context_window_total_tokens),
      cost: decimal_string(field_value(execution, :cost)),
      duration_ms: field_value(execution, :duration_ms),
      handoff: field_value(execution, :handoff),
      inserted_at: field_value(execution, :inserted_at),
      updated_at: field_value(execution, :updated_at)
    })
  end

  defp task_run_payload(task_run) do
    task_run
    |> task_run_base_payload()
    |> Map.put(:run_controls, task_run_controls_payload(task_run))
    |> version_payload()
  end

  defp task_run_base_payload(nil), do: nil

  defp task_run_base_payload(task_run) do
    %{
      id: task_run.id,
      task_id: task_run.task_id,
      project_id: task_run.project_id,
      status: TaskRunStatus.wire_value(task_run.status),
      started_at: task_run.started_at,
      ended_at: task_run.ended_at,
      stop_requested_at: task_run.stop_requested_at,
      latest_step_execution_id: task_run.latest_step_execution_id,
      outcome_kind: task_run.outcome_kind,
      outcome_context: task_run.outcome_context,
      parent_task_run_id: task_run.parent_task_run_id,
      root_task_run_id: task_run.root_task_run_id,
      triggered_by_step_execution_id: task_run.triggered_by_step_execution_id,
      inserted_at: task_run.inserted_at,
      updated_at: task_run.updated_at
    }
  end

  defp task_run_controls_payload(task_run) do
    case RunControls.for_task_run(task_run) do
      {:ok, controls} ->
        controls
        |> RunControls.to_payload()
        |> Map.update!(:active_run, &task_run_base_payload/1)

      {:error, :not_found} ->
        nil
    end
  end

  defp session_log_payload(log) do
    version_payload(%{
      id: log.id,
      step_execution_id: log.step_execution_id,
      project_id: log.project_id,
      content: log.content,
      format: field_value(log, :format),
      inserted_at: log.inserted_at,
      updated_at: log.updated_at
    })
  end

  defp field_value(resource, field) when is_map(resource), do: Map.get(resource, field)
  defp decimal_string(nil), do: nil
  defp decimal_string(%Decimal{} = decimal), do: Decimal.to_string(decimal)
  defp decimal_string(value), do: value

  defp section_payload(section) do
    version_payload(%{
      id: section.id,
      task_id: section.task_id,
      project_id: section.project_id,
      section_type: section.section_type,
      content: section.content,
      section_order: section.section_order,
      done: section.done,
      done_at: section.done_at,
      inserted_at: section.inserted_at,
      updated_at: section.updated_at
    })
  end

  defp code_ref_payload(code_ref) do
    version_payload(%{
      id: code_ref.id,
      task_id: code_ref.task_id,
      section_id: code_ref.section_id,
      project_id: code_ref.project_id,
      path: code_ref.path,
      line_start: code_ref.line_start,
      line_end: code_ref.line_end,
      name: code_ref.name,
      description: code_ref.description,
      inserted_at: code_ref.inserted_at,
      updated_at: code_ref.updated_at
    })
  end

  defp run_step_payload(data) do
    payload = %{
      id: data.execution.id,
      task_id: data.execution.task_id,
      prompt: data.rendered_prompt,
      agent_config: data.step.agent_config,
      worktree: data.task.worktree
    }

    payload =
      case data.step.output_schema do
        nil -> payload
        schema -> Map.put(payload, :output_schema, schema)
      end

    # Field omitted when false so older daemons (pre-flag) see an unchanged payload shape.
    case data.step.verbose_daemon_logging do
      true -> Map.put(payload, :verbose_daemon_logging, true)
      _ -> payload
    end
  end

  defp cancel_step_payload(data) do
    %{
      step_execution_id: data.step_execution_id,
      task_id: data.task_id
    }
  end
end
