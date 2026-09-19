defmodule Sacrum.Orchestrator.AsyncStepExecution do
  @moduledoc "Supervised worker for queued direct GraphQL step executions."

  use GenServer

  import Ecto.Query

  alias Sacrum.Accounts.StepExecutions
  alias Sacrum.Orchestrator.{ExecutionEvents, ExecutionPool}
  alias Sacrum.Realtime.CommandBroadcaster
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{StepExecution, Task}

  @terminal_statuses ~w(completed failed cancelled stopped)

  @spec child_spec(tuple()) ::
          Supervisor.child_spec()
  def child_spec({execution_id, user_id, project_id, task_run_id, pool}) do
    child_spec({execution_id, user_id, project_id, task_run_id, pool, []})
  end

  def child_spec(
        {execution_id, _user_id, _project_id, _task_run_id, _pool, _admission_opts} = args
      ) do
    %{
      id: {__MODULE__, execution_id},
      start: {__MODULE__, :start_link, [args]},
      restart: :temporary,
      type: :worker
    }
  end

  @spec start_link(tuple()) ::
          GenServer.on_start()
  def start_link({execution_id, _user_id, _project_id, _task_run_id, _pool, _opts} = args) do
    GenServer.start_link(
      __MODULE__,
      args,
      name: {:via, Registry, {Sacrum.Orchestrator.AsyncStepExecutionRegistry, execution_id}}
    )
  end

  @impl true
  def init({execution_id, user_id, project_id, task_run_id, pool, admission_opts}) do
    Registry.update_value(
      Sacrum.Orchestrator.AsyncStepExecutionRegistry,
      execution_id,
      fn _ -> pool end
    )

    {:ok,
     %{
       execution_id: execution_id,
       user_id: user_id,
       project_id: project_id,
       task_run_id: task_run_id,
       pool: pool,
       admission_opts: admission_opts,
       slot_id: nil
     }, {:continue, :run}}
  end

  @impl true
  def handle_continue(:run, state) do
    opts =
      Keyword.merge(state.admission_opts,
        attempt_id: state.execution_id,
        execution_id: state.execution_id
      )

    case ExecutionPool.request_slot(state.pool, self(), :infinity, opts) do
      {:ok, slot_id} -> run_started(%{state | slot_id: slot_id})
      {:error, :cancelled} -> finish(state)
      {:error, reason} -> fail(state, reason)
    end
  end

  @impl true
  def handle_info({:step_execution_status_changed, %{id: id, status: status}}, state)
      when id == state.execution_id and status in @terminal_statuses do
    finish(state)
  end

  defp run_started(state) do
    case claim_execution(state.execution_id) do
      {:ok, {:started, started}} ->
        case ExecutionEvents.subscribe(started.id) do
          :ok -> broadcast_if_active(state)
          {:error, reason} -> fail(state, reason)
        end

      {:ok, {:terminal, _execution}} ->
        finish(state)

      {:error, reason} ->
        fail(state, reason)
    end
  end

  defp claim_execution(execution_id) do
    Repo.transaction(fn -> claim_execution_in_transaction(execution_id) end)
  end

  defp claim_execution_in_transaction(execution_id) do
    case Repo.one(
           from(e in StepExecution,
             where: e.id == ^execution_id,
             lock: "FOR UPDATE"
           )
         ) do
      nil ->
        Repo.rollback(:execution_not_found)

      %StepExecution{status: status} = execution when status in @terminal_statuses ->
        {:terminal, execution}

      %StepExecution{} = execution ->
        claim_nonterminal_execution(execution)
    end
  end

  defp claim_nonterminal_execution(execution) do
    case StepExecutions.update(execution, %{status: "started"}) do
      {:ok, started} -> {:started, started}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp broadcast_if_active(state) do
    case Repo.get(StepExecution, state.execution_id) do
      %StepExecution{status: status} when status in @terminal_statuses ->
        finish(state)

      %StepExecution{} = execution ->
        case broadcast(execution, state.project_id) do
          :ok -> wait_for_terminal(state)
          {:error, reason} -> fail(state, reason)
        end

      nil ->
        fail(state, :execution_not_found)
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
      Task.workspace_daemon(execution.task)
    )
  end

  defp finish(state) do
    if state.slot_id, do: ExecutionPool.release_slot(state.pool, state.slot_id)
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
