defmodule Sacrum.Orchestrator.AsyncStepExecution do
  @moduledoc "Supervised worker for queued direct GraphQL step executions."

  use GenServer

  alias Sacrum.Accounts.StepExecutions
  alias Sacrum.Orchestrator.{ExecutionEvents, ExecutionPool}
  alias Sacrum.Realtime.CommandBroadcaster
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.StepExecution

  @terminal_statuses ~w(completed failed cancelled stopped)

  @spec child_spec({binary(), binary(), binary(), binary()}) :: Supervisor.child_spec()
  def child_spec({execution_id, user_id, project_id, task_run_id}) do
    %{
      id: {__MODULE__, execution_id},
      start: {__MODULE__, :start_link, [{execution_id, user_id, project_id, task_run_id}]},
      restart: :temporary,
      type: :worker
    }
  end

  @spec start_link({binary(), binary(), binary(), binary()}) :: GenServer.on_start()
  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init({execution_id, user_id, project_id, task_run_id}) do
    {:ok,
     %{
       execution_id: execution_id,
       user_id: user_id,
       project_id: project_id,
       task_run_id: task_run_id,
       slot_id: nil
     }, {:continue, :run}}
  end

  @impl true
  def handle_continue(:run, state) do
    case ExecutionPool.request_slot(self(), :infinity) do
      {:ok, slot_id} -> run_started(%{state | slot_id: slot_id})
      {:error, reason} -> fail(state, reason)
    end
  end

  @impl true
  def handle_info({:step_execution_status_changed, %{id: id, status: status}}, state)
      when id == state.execution_id and status in @terminal_statuses do
    finish(state)
  end

  defp run_started(state) do
    with %StepExecution{} = execution <- Repo.get(StepExecution, state.execution_id),
         false <- execution.status in @terminal_statuses,
         {:ok, started} <- StepExecutions.update(execution, %{status: "started"}),
         :ok <- ExecutionEvents.subscribe(started.id),
         :ok <- broadcast(started, state.project_id) do
      wait_for_terminal(state)
    else
      %StepExecution{} = execution when execution.status in @terminal_statuses -> finish(state)
      nil -> fail(state, :execution_not_found)
      {:error, reason} -> fail(state, reason)
    end
  end

  defp wait_for_terminal(state) do
    case Repo.get(StepExecution, state.execution_id) do
      %StepExecution{status: status} when status in @terminal_statuses -> finish(state)
      _ -> {:noreply, state, :hibernate}
    end
  end

  defp broadcast(%StepExecution{} = execution, _project_id) do
    execution = Repo.preload(execution, [:step, :task])

    CommandBroadcaster.broadcast_run_step(
      %{
        execution: execution,
        step: execution.step,
        task: execution.task,
        rendered_prompt: execution.prompt
      },
      execution.project_id
    )
  end

  defp finish(state) do
    if state.slot_id, do: ExecutionPool.release_slot(state.slot_id)
    {:stop, :normal, %{state | slot_id: nil}}
  end

  defp fail(state, reason) do
    if execution = Repo.get(StepExecution, state.execution_id) do
      StepExecutions.update(execution, %{
        status: "failed",
        output: "dispatch failed: #{inspect(reason)}"
      })
    end

    finish(state)
  end
end
