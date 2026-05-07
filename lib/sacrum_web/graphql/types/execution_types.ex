defmodule SacrumWeb.Graphql.Types.ExecutionTypes do
  @moduledoc """
  GraphQL type definitions for StepExecution and SessionLog resources.
  """

  use Absinthe.Schema.Notation

  require Logger

  import Absinthe.Resolution.Helpers

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.{ExecutionDispatcher, Scheduler}
  alias Sacrum.Orchestrator.TaskRuns.Root
  alias Sacrum.Repo.Broadcaster
  alias Sacrum.Repo.Schemas.TaskRun
  alias Sacrum.TaskRuns.Status, as: TaskRunStatus
  alias SacrumWeb.Graphql.ChangesetErrors

  object :task_run do
    field :id, :id
    field :task_id, :id
    field :project_id, :id
    field :user_id, :id

    field :status, :string do
      resolve(fn task_run, _args, _resolution ->
        {:ok, TaskRunStatus.wire_value(task_run.status)}
      end)
    end

    field :started_at, :datetime
    field :ended_at, :datetime
    field :stop_requested_at, :datetime
    field :latest_step_execution_id, :id
    field :outcome_kind, :string
    field :outcome_context, :json
    field :parent_task_run_id, :id
    field :root_task_run_id, :id
    field :triggered_by_step_execution_id, :id
    field :inserted_at, :datetime
    field :updated_at, :datetime

    field :task, :task do
      resolve(dataloader(Accounts.Tasks))
    end

    field :project, :project do
      resolve(dataloader(Accounts.Projects))
    end

    field :latest_step_execution, :step_execution do
      resolve(dataloader(Accounts.StepExecutions))
    end

    field :parent_task_run, :task_run do
      resolve(dataloader(Accounts.TaskRuns))
    end

    field :root_task_run, :task_run do
      resolve(dataloader(Accounts.TaskRuns))
    end

    field :triggered_by_step_execution, :step_execution do
      resolve(dataloader(Accounts.StepExecutions))
    end

    field :child_task_runs, list_of(:task_run) do
      resolve(dataloader(Accounts.TaskRuns))
    end

    field :step_executions, list_of(:step_execution) do
      resolve(dataloader(Accounts.StepExecutions))
    end
  end

  object :step_execution do
    field :id, :id
    field :task_id, :id
    field :task_run_id, :id
    field :step_name, :string
    field :status, :string
    field :context, :json
    field :prompt, :string
    field :output, :string
    field :transition_result, :string
    field :model, :string
    field :model_provider, :string
    field :input_tokens, :integer
    field :output_tokens, :integer
    field :cost, :decimal
    field :duration_ms, :integer
    field :handoff, :json
    field :inserted_at, :datetime
    field :updated_at, :datetime

    # Associations
    field :workflow_id, :id

    field :workflow, :workflow do
      resolve(dataloader(Accounts.Workflows))
    end

    field :task_run, :task_run do
      resolve(dataloader(Accounts.TaskRuns))
    end

    field :project_id, :id

    field :project, :project do
      resolve(dataloader(Accounts.Projects))
    end

    field :session_logs, list_of(:session_log) do
      resolve(dataloader(Accounts.SessionLogs))
    end
  end

  object :session_log do
    field :id, :id
    field :content, :string
    field :inserted_at, :datetime
    field :updated_at, :datetime

    # Associations
    field :step_execution_id, :id

    field :step_execution, :step_execution do
      resolve(dataloader(Accounts.StepExecutions))
    end

    field :project_id, :id

    field :project, :project do
      resolve(dataloader(Accounts.Projects))
    end
  end

  object :task_run_trace do
    field :root_task_run_id, :id
    field :task_runs, list_of(:task_run)
    field :step_executions, list_of(:step_execution)
    field :session_logs, list_of(:session_log)
  end

  object :execution_queries do
    field :active_run, :task_run do
      arg(:task_id, non_null(:uuid4))

      resolve(fn %{task_id: task_id}, %{context: %{current_user: user}} ->
        with {:ok, _task} <- Accounts.Tasks.find(user.id, task_id) do
          case Accounts.TaskRuns.get_active_for_task(user.id, task_id) do
            {:ok, task_run} -> {:ok, task_run}
            {:error, :not_found} -> {:ok, nil}
          end
        end
      end)
    end

    field :task_runs, list_of(:task_run) do
      arg(:task_id, non_null(:uuid4))

      resolve(fn %{task_id: task_id}, %{context: %{current_user: user}} ->
        with {:ok, _task} <- Accounts.Tasks.find(user.id, task_id) do
          {:ok, Accounts.TaskRuns.list_by(user.id, conditions: [task_id: task_id])}
        end
      end)
    end

    field :task_run, :task_run do
      arg(:id, non_null(:uuid4))

      resolve(fn %{id: id}, %{context: %{current_user: user}} ->
        Accounts.TaskRuns.get_by(user.id, conditions: [id: id])
      end)
    end

    field :task_run_trace, :task_run_trace do
      arg(:root_task_run_id, non_null(:uuid4))

      resolve(fn %{root_task_run_id: root_task_run_id}, %{context: %{current_user: user}} ->
        with {:ok, root_run} <-
               Accounts.TaskRuns.get_by(user.id, conditions: [id: root_task_run_id]) do
          {:ok,
           %{
             root_task_run_id: root_run.id,
             task_runs: Accounts.TaskRuns.list_for_trace(user.id, root_run.id),
             step_executions:
               Accounts.TaskRuns.list_step_executions_for_trace(user.id, root_run.id),
             session_logs: Accounts.TaskRuns.list_session_logs_for_trace(user.id, root_run.id)
           }}
        end
      end)
    end

    field :step_executions, list_of(:step_execution) do
      arg(:task_id, non_null(:uuid4))

      resolve(fn %{task_id: task_id}, %{context: %{current_user: user}} ->
        with {:ok, _task} <- Accounts.Tasks.find(user.id, task_id) do
          executions = Accounts.StepExecutions.list_by(user.id, conditions: [task_id: task_id])
          {:ok, executions}
        end
      end)
    end

    field :step_execution, :step_execution do
      arg(:id, non_null(:uuid4))

      resolve(fn %{id: id}, %{context: %{current_user: user}} ->
        case Accounts.StepExecutions.get_by(user.id, conditions: [id: id]) do
          {:ok, execution} -> {:ok, execution}
          error -> error
        end
      end)
    end

    field :session_logs, list_of(:session_log) do
      arg(:step_execution_id, non_null(:uuid4))

      resolve(fn %{step_execution_id: exec_id}, %{context: %{current_user: user}} ->
        with {:ok, _exec} <- Accounts.StepExecutions.get_by(user.id, conditions: [id: exec_id]) do
          logs = Accounts.SessionLogs.list_by(user.id, conditions: [step_execution_id: exec_id])
          {:ok, logs}
        end
      end)
    end
  end

  object :execution_mutations do
    field :run_workflow, :task_run do
      arg(:task_id, non_null(:uuid4))

      resolve(fn %{task_id: task_id}, %{context: %{current_user: user}} ->
        with {:ok, _task} <- schedule_task_for_mutation(:run_workflow, task_id, user) do
          Accounts.TaskRuns.get_active_for_task(user.id, task_id)
        end
      end)
    end

    field :stop_run, :task_run do
      arg(:task_id, :uuid4)
      arg(:task_run_id, :uuid4)

      resolve(fn args, %{context: %{current_user: user}} ->
        stop_run(args, user)
      end)
    end

    field :create_step_execution, :step_execution do
      arg(:task_id, non_null(:uuid4))
      arg(:workflow_id, non_null(:uuid4))
      arg(:step_name, non_null(:string))
      arg(:status, :string)
      arg(:context, :json)
      arg(:prompt, :string)
      arg(:output, :string)
      arg(:transition_result, :string)
      arg(:model, :string)
      arg(:model_provider, :string)
      arg(:input_tokens, :integer)
      arg(:output_tokens, :integer)
      arg(:cost, :decimal)
      arg(:duration_ms, :integer)

      resolve(fn args, %{context: %{current_user: user}} ->
        task_id = Map.get(args, :task_id)
        workflow_id = Map.get(args, :workflow_id)

        with {:ok, task} <- Accounts.Tasks.find(user.id, task_id),
             {:ok, _workflow} <- Accounts.Workflows.get_by(user.id, conditions: [id: workflow_id]) do
          attrs = Map.put(args, :project_id, task.project_id)
          Accounts.StepExecutions.insert(user.id, attrs)
        end
      end)
    end

    field :update_step_execution, :step_execution do
      arg(:id, non_null(:uuid4))
      arg(:step_name, :string)
      arg(:status, :string)
      arg(:context, :json)
      arg(:prompt, :string)
      arg(:output, :string)
      arg(:transition_result, :string)
      arg(:model, :string)
      arg(:model_provider, :string)
      arg(:input_tokens, :integer)
      arg(:output_tokens, :integer)
      arg(:cost, :decimal)
      arg(:duration_ms, :integer)

      resolve(fn %{id: id} = args, %{context: %{current_user: user}} ->
        Logger.info(
          "[updateStepExecution] Mutation called: exec=#{id} attrs=#{inspect(Map.keys(Map.drop(args, [:id])))}"
        )

        with {:ok, execution} <- Accounts.StepExecutions.get_by(user.id, conditions: [id: id]) do
          attrs = Map.drop(args, [:id])

          Logger.info(
            "[updateStepExecution] Found execution: status=#{execution.status}, updating with #{inspect(attrs)}"
          )

          case Accounts.StepExecutions.update(execution, attrs) do
            {:error, %Ecto.Changeset{} = changeset} ->
              {:error, ChangesetErrors.format(changeset)}

            result ->
              result
          end
        end
      end)
    end

    field :create_session_log, :session_log do
      arg(:step_execution_id, non_null(:uuid4))
      arg(:content, non_null(:string))

      resolve(fn args, %{context: %{current_user: user}} ->
        exec_id = Map.get(args, :step_execution_id)

        with {:ok, exec} <- Accounts.StepExecutions.get_by(user.id, conditions: [id: exec_id]) do
          attrs = Map.put(args, :project_id, exec.project_id)
          Accounts.SessionLogs.insert(user.id, attrs)
        end
      end)
    end

    field :run_step, :step_execution do
      arg(:task_id, non_null(:uuid4))
      arg(:step_id, non_null(:uuid4))

      resolve(fn args, %{context: %{current_user: user}} ->
        task_id = Map.get(args, :task_id)
        step_id = Map.get(args, :step_id)

        with {:ok, task} <-
               Accounts.Tasks.get_by(user.id,
                 conditions: [id: task_id],
                 preloads: [:sections, :code_refs, :workflow, :current_step]
               ),
             :ok <- check_daemon_presence(task.project_id) do
          with {:ok, task_run} <- Root.get_or_create(task) do
            ExecutionDispatcher.create_and_dispatch(user.id, task, step_id, task_run)
          end
        end
      end)
    end

    @spec check_daemon_presence(binary()) :: :ok | {:error, String.t()}
    defp check_daemon_presence(project_id) do
      daemon_presence_required = Application.get_env(:sacrum, :daemon_presence_required, false)

      if daemon_presence_required do
        if Sacrum.DaemonRegistry.daemon_connected?(project_id) do
          :ok
        else
          {:error, "No daemon is currently connected for this project"}
        end
      else
        :ok
      end
    end

    defp stop_run(%{task_id: task_id, task_run_id: task_run_id}, _user)
         when is_binary(task_id) and is_binary(task_run_id),
         do: {:error, "Provide exactly one of taskId or taskRunId"}

    defp stop_run(%{task_run_id: task_run_id}, user) when is_binary(task_run_id) do
      with {:ok, task_run} <- Accounts.TaskRuns.get_by(user.id, conditions: [id: task_run_id]) do
        stop_loaded_task_run(task_run)
      end
    end

    defp stop_run(%{task_id: task_id}, user) when is_binary(task_id) do
      with {:ok, _task} <- Accounts.Tasks.find(user.id, task_id),
           {:ok, task_run} <- active_task_run_or_nil(user.id, task_id) do
        stop_loaded_task_run(task_run)
      end
    end

    defp stop_run(_args, _user), do: {:error, "Provide taskId or taskRunId"}

    defp active_task_run_or_nil(user_id, task_id) do
      case Accounts.TaskRuns.get_active_for_task(user_id, task_id) do
        {:ok, task_run} -> {:ok, task_run}
        {:error, :not_found} -> {:ok, nil}
      end
    end

    defp stop_loaded_task_run(nil), do: {:ok, nil}

    defp stop_loaded_task_run(%TaskRun{} = task_run) do
      with {:ok, stopped_run} <- Sacrum.Orchestrator.stop_task_run(task_run) do
        {:ok, stopped_task_run(stopped_run, task_run)}
      end
    end

    defp stopped_task_run(%TaskRun{} = task_run, _fallback), do: task_run
    defp stopped_task_run(:not_running, %TaskRun{} = task_run), do: task_run

    field :cancel_step_execution, :step_execution do
      arg(:step_execution_id, non_null(:uuid4))

      resolve(fn %{step_execution_id: execution_id}, %{context: %{current_user: user}} ->
        with {:ok, execution} <-
               Accounts.StepExecutions.get_by(user.id, conditions: [id: execution_id]) do
          # Only allow cancellation if the execution is in pending or in_progress status
          case execution.status do
            status when status in ["pending", "in_progress"] ->
              # Update the execution status to cancelling
              with {:ok, updated_execution} <-
                     Accounts.StepExecutions.update(execution, %{status: "cancelling"}) do
                # After status update, broadcast the cancel_step event to the daemon
                Broadcaster.broadcast_cancel_step(updated_execution, updated_execution.project_id)
                {:ok, updated_execution}
              end

            _ ->
              # Execution is already completed, failed, or in another terminal state
              {:error, "Cannot cancel an execution with status: #{execution.status}"}
          end
        end
      end)
    end

    field :orchestrate_task, :task do
      arg(:task_id, non_null(:uuid4))

      resolve(fn %{task_id: task_id}, %{context: %{current_user: user}} ->
        schedule_task_for_mutation(:orchestrate_task, task_id, user)
      end)
    end

    defp schedule_task_for_mutation(operation, task_id, user) do
      operation_name = operation_name(operation)
      Logger.info("[#{operation_name}] Mutation called for task_id=#{task_id} user=#{user.id}")

      with {:ok, task} <- Accounts.Tasks.get_by(user.id, conditions: [id: task_id]),
           _ =
             Logger.info(
               "[#{operation_name}] Task found, workflow_id=#{task.workflow_id}, current_step_id=#{task.current_step_id}"
             ),
           :ok <- Scheduler.schedule_task(%{id: task_id}) do
        Logger.info("[#{operation_name}] Scheduler accepted task #{task_id}")
        {:ok, task}
      else
        {:error, reason} -> schedule_task_error(operation, task_id, reason)
      end
    end

    defp schedule_task_error(operation, task_id, :not_found) do
      Logger.warning("[#{operation_name(operation)}] Task #{task_id} not found")
      {:error, "Task not found"}
    end

    defp schedule_task_error(operation, task_id, :no_workflow_assigned) do
      Logger.warning("[#{operation_name(operation)}] Task #{task_id} has no workflow")
      {:error, "Task has no workflow assigned"}
    end

    defp schedule_task_error(:run_workflow, task_id, :task_already_completed) do
      Logger.warning("[runWorkflow] Task #{task_id} already completed")
      {:error, "Cannot run a completed task"}
    end

    defp schedule_task_error(:orchestrate_task, task_id, :task_already_completed) do
      Logger.warning("[orchestrateTask] Task #{task_id} already completed")
      {:error, "Cannot orchestrate a completed task"}
    end

    defp schedule_task_error(:run_workflow, task_id, :orchestrator_already_running) do
      Logger.warning("[runWorkflow] Task #{task_id} workflow run already running")
      {:error, "Workflow run is already running for this task"}
    end

    defp schedule_task_error(:orchestrate_task, task_id, :orchestrator_already_running) do
      Logger.warning("[orchestrateTask] Task #{task_id} orchestrator already running")
      {:error, "Orchestration is already running for this task"}
    end

    defp schedule_task_error(:run_workflow, task_id, reason) do
      Logger.error("[runWorkflow] Failed for task #{task_id}: #{inspect(reason)}")
      {:error, "Failed to start workflow run: #{inspect(reason)}"}
    end

    defp schedule_task_error(:orchestrate_task, task_id, reason) do
      Logger.error("[orchestrateTask] Failed for task #{task_id}: #{inspect(reason)}")
      {:error, "Failed to schedule task: #{inspect(reason)}"}
    end

    defp operation_name(:run_workflow), do: "runWorkflow"
    defp operation_name(:orchestrate_task), do: "orchestrateTask"
  end
end
