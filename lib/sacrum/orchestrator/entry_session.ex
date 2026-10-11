defmodule Sacrum.Orchestrator.EntrySession do
  @moduledoc """
  The session directive a TaskRun's first dispatch enters with
  (`TaskRun.entry_session`) when the conversation it resumes or forks lives in
  a directly linked run:

    * bypassing a stop step: the edge leaving the stop step names a step of
      the run that stopped at that boundary;
    * a child run created by `wait_children`: the step's fork directive names
      a step of the parent run.

  The directive is the authored `{mode, step_id}` plus a `task_run_id` that
  only the engine sets. It is stored with the run so a restart before the
  first dispatch still applies it, and it applies only while the run has no
  executions; later turns continue in the run itself.
  """

  import Ecto.Query

  alias Sacrum.Orchestrator.{FSMData, SessionBinding, WorkflowGraph}
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.TaskRun

  @doc """
  The entry directive for the run bypassing `stop_step_id` towards
  `next_step_id`, or nil when the edge carries none. A resume or fork names
  the task's previous run when that run ended at this stop step; without one
  the directive names no linked run and fails with `session_not_found`.
  """
  @spec stop_bypass(FSMData.t(), binary(), binary()) :: map() | nil
  def stop_bypass(data, stop_step_id, next_step_id) do
    directive = WorkflowGraph.transition_session(data, stop_step_id, next_step_id)

    case {SessionBinding.continues?(directive), boundary_run_id(data, stop_step_id)} do
      {true, run_id} when is_binary(run_id) -> Map.put(directive, "task_run_id", run_id)
      _other -> directive
    end
  end

  @doc """
  The entry directive for a child run of `parent_task_run` created by a
  `wait_children` step whose config carries `session`, or nil.
  """
  @spec child(map() | nil, TaskRun.t()) :: map() | nil
  def child(%{"mode" => "fork", "step_id" => step_id}, %TaskRun{id: parent_run_id}),
    do: %{"mode" => "fork", "step_id" => step_id, "task_run_id" => parent_run_id}

  def child(_session, _parent_task_run), do: nil

  @doc """
  Seeds `pending_session` from the run's entry directive while the run has
  not dispatched anything yet.
  """
  @spec seed(FSMData.t()) :: FSMData.t()
  def seed(
        %FSMData{
          pending_session: nil,
          task_run: %TaskRun{latest_step_execution_id: nil, entry_session: %{} = entry}
        } = data
      ),
      do: %{data | pending_session: entry}

  def seed(data), do: data

  # The task's latest run before this one, when it ended at `stop_step_id`.
  defp boundary_run_id(data, stop_step_id) do
    previous =
      Repo.one(
        from(r in TaskRun,
          where: r.task_id == ^data.task.id and r.id != ^data.task_run_id,
          order_by: [desc: r.inserted_at, desc: r.id],
          limit: 1
        )
      )

    case previous do
      %TaskRun{
        outcome_kind: "run_boundary",
        outcome_context: %{"reason" => "stop_step", "step_id" => ^stop_step_id}
      } ->
        previous.id

      _other ->
        nil
    end
  end
end
