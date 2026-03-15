defmodule SacrumWeb.Graphql.Types.ExecutionTypes do
  @moduledoc """
  GraphQL type definitions for StepExecution and SessionLog resources.
  """

  use Absinthe.Schema.Notation
  import Absinthe.Resolution.Helpers

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.{ExecutionDispatcher, Scheduler}
  alias Sacrum.Repo.Broadcaster

  object :step_execution do
    field :id, :id
    field :task_id, :id
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
    field :inserted_at, :datetime
    field :updated_at, :datetime

    # Associations
    field :workflow_id, :id

    field :workflow, :workflow do
      resolve(dataloader(Accounts.Workflows))
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

  object :execution_queries do
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
        with {:ok, execution} <- Accounts.StepExecutions.get_by(user.id, conditions: [id: id]) do
          attrs = Map.drop(args, [:id])
          Accounts.StepExecutions.update(execution, attrs)
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
                 conditions: [id: task_id]
               ),
             :ok <- check_daemon_presence(task.project_id) do
          ExecutionDispatcher.create_and_dispatch(user.id, task, step_id)
        end
      end)
    end

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
        with {:ok, task} <- Accounts.Tasks.get_by(user.id, conditions: [id: task_id]),
             :ok <- Scheduler.schedule_task(%{id: task_id}) do
          {:ok, task}
        else
          {:error, :not_found} -> {:error, "Task not found"}
          {:error, :no_workflow_assigned} -> {:error, "Task has no workflow assigned"}
          {:error, :task_already_completed} -> {:error, "Cannot orchestrate a completed task"}
          {:error, :orchestrator_already_running} -> {:error, "Orchestration is already running for this task"}
          {:error, reason} -> {:error, "Failed to schedule task: #{inspect(reason)}"}
        end
      end)
    end
  end
end
