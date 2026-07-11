defmodule Sacrum.Realtime.Cdc.Projector do
  @moduledoc """
  Projects committed WalEx row events into default-client ProjectChannel payloads.

  The projector is intentionally regular-client only. Daemon commands such as
  `run_step` and `cancel_step` stay on the explicit orchestration path.
  """

  use GenServer

  import Ecto.Query

  alias Sacrum.Repo

  alias Sacrum.Repo.Schemas.{
    CodeRef,
    SessionLog,
    StepExecution,
    StepTransition,
    Task,
    TaskDependency,
    TaskRun,
    TaskSection,
    Workflow,
    WorkflowStep,
    WorkflowTransition
  }

  alias Sacrum.TaskRuns.Status, as: TaskRunStatus
  alias SacrumWeb.ProjectChannel

  require Logger

  @name __MODULE__

  @task_bucket_identity_fields [:archived, :level, :current_step_id, :workflow_id]

  @schema_by_table %{
    "tasks" => Task,
    "workflows" => Workflow,
    "workflow_steps" => WorkflowStep,
    "step_transitions" => StepTransition,
    "workflow_transitions" => WorkflowTransition,
    "step_executions" => StepExecution,
    "task_runs" => TaskRun,
    "session_logs" => SessionLog,
    "task_sections" => TaskSection,
    "task_dependencies" => TaskDependency,
    "code_refs" => CodeRef
  }

  @channel_broadcasts %{
    "task_created" => :broadcast_task_created,
    "task_updated" => :broadcast_task_updated,
    "task_deleted" => :broadcast_task_deleted,
    "task_parent_changed" => :broadcast_task_parent_changed,
    "task_dependency_created" => :broadcast_task_dependency_created,
    "task_dependency_deleted" => :broadcast_task_dependency_deleted,
    "workflow_created" => :broadcast_workflow_created,
    "workflow_updated" => :broadcast_workflow_updated,
    "workflow_deleted" => :broadcast_workflow_deleted,
    "step_created" => :broadcast_step_created,
    "step_updated" => :broadcast_step_updated,
    "step_deleted" => :broadcast_step_deleted,
    "step_transition_created" => :broadcast_step_transition_created,
    "step_transition_deleted" => :broadcast_step_transition_deleted,
    "workflow_transition_created" => :broadcast_workflow_transition_created,
    "workflow_transition_deleted" => :broadcast_workflow_transition_deleted,
    "step_execution_created" => :broadcast_step_execution_created,
    "step_execution_status_changed" => :broadcast_step_execution_status_changed,
    "task_run_created" => :broadcast_task_run_created,
    "task_run_updated" => :broadcast_task_run_updated,
    "task_run_step_changed" => :broadcast_task_run_step_changed,
    "task_step_changed" => :broadcast_task_step_changed,
    "session_log_created" => :broadcast_session_log_created,
    "session_log_updated" => :broadcast_session_log_updated,
    "section_created" => :broadcast_section_created,
    "section_updated" => :broadcast_section_updated,
    "section_deleted" => :broadcast_section_deleted,
    "code_ref_created" => :broadcast_code_ref_created,
    "code_ref_updated" => :broadcast_code_ref_updated,
    "code_ref_deleted" => :broadcast_code_ref_deleted
  }

  @type dispatch_result :: %{
          event: String.t(),
          project_id: String.t(),
          status: :dispatched
        }

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(init_arg) do
    GenServer.start_link(__MODULE__, init_arg, name: @name)
  end

  @spec dispatch([WalEx.Event.t()] | WalEx.Event.t()) :: {:ok, [dispatch_result()]}
  def dispatch(events) do
    GenServer.call(@name, {:dispatch, List.wrap(events)}, :infinity)
  end

  @spec project_events([WalEx.Event.t()] | WalEx.Event.t()) :: {:ok, [dispatch_result()]}
  def project_events(events) do
    events = List.wrap(events)
    context = projection_context(events)

    events
    |> Enum.flat_map(&project_event(&1, context))
    |> then(&{:ok, &1})
  end

  @impl true
  def init(_init_arg), do: {:ok, %{}}

  @impl true
  def handle_call({:dispatch, events}, _from, state) do
    {:reply, project_events(events), state}
  end

  defp project_event(%WalEx.Event{} = event, context) do
    event
    |> projections(context)
    |> Enum.map(&dispatch_projection/1)
  end

  defp projections(%WalEx.Event{source: %{table: "tasks"}, type: :update} = event, context) do
    task = record_to_struct!("tasks", event.new_record)

    base_projection =
      projection(
        "task_updated",
        task.project_id,
        Map.put(task, :previous, previous_task_bucket_identity(event))
      )

    [
      base_projection
      | task_parent_projections(event, task) ++ task_step_projections(event, task, context)
    ]
  end

  defp projections(
         %WalEx.Event{source: %{table: "task_runs"}, type: :insert, new_record: record},
         context
       ) do
    task_run = record_to_struct!("task_runs", record)

    [
      projection("task_run_created", task_run.project_id, task_run)
      | task_run_start_projections(task_run, context)
    ]
  end

  defp projections(%WalEx.Event{source: %{table: "task_runs"}, type: :update} = event, context) do
    task_run = record_to_struct!("task_runs", event.new_record)

    [
      projection("task_run_updated", task_run.project_id, task_run)
      | task_run_end_projections(event, task_run, context)
    ]
  end

  defp projections(%WalEx.Event{} = event, _context), do: projections(event)

  defp projections(%WalEx.Event{source: %{table: "tasks"}, type: :insert, new_record: record}) do
    task = record_to_struct!("tasks", record)
    [projection("task_created", task.project_id, task)]
  end

  defp projections(%WalEx.Event{source: %{table: "tasks"}, type: :delete, old_record: record}) do
    task = record_to_struct!("tasks", record)
    [projection("task_deleted", task.project_id, task)]
  end

  defp projections(%WalEx.Event{
         source: %{table: "task_dependencies"},
         type: :insert,
         new_record: record
       }) do
    dependency = record_to_struct!("task_dependencies", record)
    [projection("task_dependency_created", dependency.project_id, dependency)]
  end

  defp projections(%WalEx.Event{
         source: %{table: "task_dependencies"},
         type: :delete,
         old_record: record
       }) do
    dependency = record_to_struct!("task_dependencies", record)
    [projection("task_dependency_deleted", dependency.project_id, dependency)]
  end

  defp projections(%WalEx.Event{source: %{table: "workflows"}, type: :insert, new_record: record}) do
    workflow = record_to_struct!("workflows", record)
    [projection("workflow_created", workflow.project_id, workflow)]
  end

  defp projections(%WalEx.Event{source: %{table: "workflows"}, type: :update, new_record: record}) do
    workflow = record_to_struct!("workflows", record)
    [projection("workflow_updated", workflow.project_id, workflow)]
  end

  defp projections(%WalEx.Event{source: %{table: "workflows"}, type: :delete, old_record: record}) do
    workflow = record_to_struct!("workflows", record)
    [projection("workflow_deleted", workflow.project_id, workflow)]
  end

  defp projections(%WalEx.Event{
         source: %{table: "workflow_steps"},
         type: :insert,
         new_record: record
       }) do
    step = record_to_struct!("workflow_steps", record)
    [projection("step_created", step.project_id, step)]
  end

  defp projections(%WalEx.Event{
         source: %{table: "workflow_steps"},
         type: :update,
         new_record: record
       }) do
    step = record_to_struct!("workflow_steps", record)
    [projection("step_updated", step.project_id, step)]
  end

  defp projections(%WalEx.Event{
         source: %{table: "workflow_steps"},
         type: :delete,
         old_record: record
       }) do
    step = record_to_struct!("workflow_steps", record)
    [projection("step_deleted", step.project_id, step)]
  end

  defp projections(%WalEx.Event{
         source: %{table: "step_transitions"},
         type: :insert,
         new_record: record
       }) do
    transition = record_to_struct!("step_transitions", record)
    [projection("step_transition_created", transition.project_id, transition)]
  end

  defp projections(%WalEx.Event{
         source: %{table: "step_transitions"},
         type: :delete,
         old_record: record
       }) do
    transition = record_to_struct!("step_transitions", record)
    [projection("step_transition_deleted", transition.project_id, transition)]
  end

  defp projections(%WalEx.Event{
         source: %{table: "workflow_transitions"},
         type: :insert,
         new_record: record
       }) do
    transition = record_to_struct!("workflow_transitions", record)
    [projection("workflow_transition_created", transition.project_id, transition)]
  end

  defp projections(%WalEx.Event{
         source: %{table: "workflow_transitions"},
         type: :delete,
         old_record: record
       }) do
    transition = record_to_struct!("workflow_transitions", record)
    [projection("workflow_transition_deleted", transition.project_id, transition)]
  end

  defp projections(%WalEx.Event{
         source: %{table: "step_executions"},
         type: :insert,
         new_record: record
       }) do
    execution = record_to_struct!("step_executions", record)
    [projection("step_execution_created", execution.project_id, execution)]
  end

  defp projections(%WalEx.Event{source: %{table: "step_executions"}, type: :update} = event) do
    if changed?(event, :status) do
      execution = record_to_struct!("step_executions", event.new_record)
      [projection("step_execution_status_changed", execution.project_id, execution)]
    else
      []
    end
  end

  defp projections(%WalEx.Event{
         source: %{table: "session_logs"},
         type: :insert,
         new_record: record
       }) do
    log = record_to_struct!("session_logs", record)
    [projection("session_log_created", log.project_id, log)]
  end

  defp projections(%WalEx.Event{
         source: %{table: "session_logs"},
         type: :update,
         new_record: record
       }) do
    log = record_to_struct!("session_logs", record)
    [projection("session_log_updated", log.project_id, log)]
  end

  defp projections(%WalEx.Event{
         source: %{table: "task_sections"},
         type: :insert,
         new_record: record
       }) do
    section = record_to_struct!("task_sections", record)
    [projection("section_created", section.project_id, section)]
  end

  defp projections(%WalEx.Event{
         source: %{table: "task_sections"},
         type: :update,
         new_record: record
       }) do
    section = record_to_struct!("task_sections", record)
    [projection("section_updated", section.project_id, section)]
  end

  defp projections(%WalEx.Event{
         source: %{table: "task_sections"},
         type: :delete,
         old_record: record
       }) do
    section = record_to_struct!("task_sections", record)
    [projection("section_deleted", section.project_id, section)]
  end

  defp projections(%WalEx.Event{
         source: %{table: "code_refs"},
         type: :insert,
         new_record: record
       }) do
    code_ref = record_to_struct!("code_refs", record)
    [projection("code_ref_created", code_ref.project_id, code_ref)]
  end

  defp projections(%WalEx.Event{
         source: %{table: "code_refs"},
         type: :update,
         new_record: record
       }) do
    code_ref = record_to_struct!("code_refs", record)
    [projection("code_ref_updated", code_ref.project_id, code_ref)]
  end

  defp projections(%WalEx.Event{
         source: %{table: "code_refs"},
         type: :delete,
         old_record: record
       }) do
    code_ref = record_to_struct!("code_refs", record)
    [projection("code_ref_deleted", code_ref.project_id, code_ref)]
  end

  defp projections(%WalEx.Event{}), do: []

  defp projection_context(events) do
    Enum.reduce(events, %{task_runs_by_task_id: %{}, tasks_by_id: %{}}, fn event, acc ->
      acc
      |> put_task_context(event)
      |> put_task_run_context(event)
    end)
  end

  defp put_task_context(acc, %WalEx.Event{source: %{table: "tasks"}, type: type} = event)
       when type in [:insert, :update] do
    task = record_to_struct!("tasks", event.new_record)
    put_in(acc, [:tasks_by_id, task.id], task)
  end

  defp put_task_context(acc, _event), do: acc

  defp put_task_run_context(acc, %WalEx.Event{source: %{table: "task_runs"}, type: type} = event)
       when type in [:insert, :update] do
    task_run = record_to_struct!("task_runs", event.new_record)

    context = %{
      task_run: task_run,
      left_active?: type == :update and status_left_active?(event)
    }

    put_in(acc, [:task_runs_by_task_id, task_run.task_id], context)
  end

  defp put_task_run_context(acc, _event), do: acc

  defp task_parent_projections(%WalEx.Event{} = event, %Task{} = task) do
    if changed?(event, :parent_id) do
      from_parent_id = old_value(event, :parent_id)
      to_parent_id = task.parent_id

      if from_parent_id == to_parent_id do
        []
      else
        [
          projection("task_parent_changed", task.project_id, %{
            task_id: task.id,
            project_id: task.project_id,
            from_parent_id: from_parent_id,
            to_parent_id: to_parent_id,
            level: task.level
          })
        ]
      end
    else
      []
    end
  end

  defp task_step_projections(%WalEx.Event{} = event, %Task{} = task, context) do
    if changed?(event, :current_step_id) do
      do_task_step_projections(event, task, context)
    else
      []
    end
  end

  defp do_task_step_projections(%WalEx.Event{} = event, %Task{} = task, context) do
    from_step_id = old_value(event, :current_step_id)
    to_step_id = task.current_step_id

    cond do
      from_step_id == to_step_id ->
        []

      task_run = task_run_for_step_change(task.id, context) ->
        [
          projection("task_run_step_changed", task.project_id, %{
            task_run_id: task_run.id,
            task_id: task.id,
            from_step_id: from_step_id,
            to_step_id: to_step_id,
            status: task_run.status,
            level: task.level
          })
        ]

      true ->
        [
          projection("task_step_changed", task.project_id, %{
            task_id: task.id,
            from_step_id: from_step_id,
            to_step_id: to_step_id,
            workflow_id: task.workflow_id,
            level: task.level
          })
        ]
    end
  end

  defp task_run_start_projections(%TaskRun{} = task_run, context) do
    case task_for_task_run(task_run, context) do
      %Task{} = task ->
        [
          projection("task_run_step_changed", task_run.project_id, %{
            task_run_id: task_run.id,
            task_id: task.id,
            from_step_id: nil,
            to_step_id: task.current_step_id,
            status: task_run.status,
            level: task.level
          })
        ]

      nil ->
        []
    end
  end

  defp task_run_end_projections(%WalEx.Event{} = event, %TaskRun{} = task_run, context) do
    if status_left_active?(event) do
      case task_for_task_run(task_run, context) do
        %Task{} = task ->
          [
            projection("task_run_step_changed", task_run.project_id, %{
              task_run_id: task_run.id,
              task_id: task.id,
              from_step_id: task.current_step_id,
              to_step_id: nil,
              status: task_run.status,
              level: task.level
            })
          ]

        nil ->
          []
      end
    else
      []
    end
  end

  defp task_run_for_step_change(task_id, context) do
    case get_in(context, [:task_runs_by_task_id, task_id]) do
      %{task_run: %TaskRun{} = task_run, left_active?: true} ->
        task_run

      %{task_run: %TaskRun{} = task_run} ->
        if TaskRunStatus.active?(normalize_task_run_status(task_run.status)) do
          task_run
        end

      _ ->
        active_task_run(task_id)
    end
  end

  defp task_for_task_run(%TaskRun{task_id: task_id}, context) do
    Map.get(context.tasks_by_id, task_id) || Repo.get(Task, task_id)
  end

  defp dispatch_projection(projection) do
    emit(projection)
    %{event: projection.event, project_id: projection.project_id, status: :dispatched}
  rescue
    exception ->
      Logger.error(
        "CDC projection failed for #{inspect(projection.event)}: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      reraise exception, __STACKTRACE__
  end

  defp emit(%{project_id: project_id, payload: payload, channel_function: function}) do
    apply(ProjectChannel, function, [project_id, payload])
  end

  defp projection(event, project_id, payload, channel_function \\ nil) do
    %{
      event: event,
      project_id: project_id,
      payload: payload,
      channel_function: channel_function || Map.fetch!(@channel_broadcasts, event)
    }
  end

  defp record_to_struct!(table, record) when is_map(record) do
    schema = Map.fetch!(@schema_by_table, table)

    attrs =
      schema
      |> schema_fields()
      |> Map.new(fn field -> {field, value(record, field)} end)

    struct(schema, attrs)
  end

  defp schema_fields(schema), do: schema.__schema__(:fields)

  defp active_task_run(task_id) do
    TaskRun
    |> where([tr], tr.task_id == ^task_id)
    |> where([tr], tr.status in ^TaskRunStatus.active_statuses())
    |> order_by([tr], desc: tr.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  defp status_left_active?(%WalEx.Event{} = event) do
    old_status = old_value(event, :status)
    new_status = new_value(event, :status)

    TaskRunStatus.active?(normalize_task_run_status(old_status)) and
      not TaskRunStatus.active?(normalize_task_run_status(new_status))
  end

  defp changed?(%WalEx.Event{changes: changes}, field) when is_map(changes) do
    Map.has_key?(changes, field) or Map.has_key?(changes, Atom.to_string(field))
  end

  defp changed?(_event, _field), do: false

  defp previous_task_bucket_identity(%WalEx.Event{} = event) do
    Map.new(
      Enum.filter(@task_bucket_identity_fields, &changed?(event, &1)),
      &{&1, old_value(event, &1)}
    )
  end

  defp old_value(%WalEx.Event{changes: changes}, field) when is_map(changes) do
    case value(changes, field) do
      %{old_value: value} -> value
      %{"old_value" => value} -> value
      _ -> value(%{}, field)
    end
  end

  defp old_value(%WalEx.Event{old_record: old_record}, field) when is_map(old_record) do
    value(old_record, field)
  end

  defp old_value(_event, _field), do: nil

  defp new_value(%WalEx.Event{new_record: new_record}, field) when is_map(new_record) do
    value(new_record, field)
  end

  defp new_value(_event, _field), do: nil

  defp value(map, field) when is_map(map) and is_atom(field) do
    cond do
      Map.has_key?(map, field) -> Map.fetch!(map, field)
      Map.has_key?(map, Atom.to_string(field)) -> Map.fetch!(map, Atom.to_string(field))
      true -> nil
    end
  end

  defp normalize_task_run_status(status) when is_binary(status) do
    case status do
      "queued" -> :queued
      "executing" -> :executing
      "waiting" -> :waiting
      "stopping" -> :stopping
      "stopped" -> :stopped
      "completed" -> :completed
      "failed" -> :failed
      _ -> status
    end
  end

  defp normalize_task_run_status(status), do: status
end
