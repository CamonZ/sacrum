defmodule Sacrum.Repo.Attention do
  @moduledoc """
  Compute and query the Attention zone rows for the Command Center.

  The Attention zone surfaces four types of issues that require human oversight:
  1. Failed runs — engine declared :failed
  2. Dead-orchestrator runs — orchestrator process not alive AND run is not in a human-intervention step
  3. Gates awaiting human input — tasks in steps with step_type="wait_children"
  4. Context-window pressure — per-step execution >100k tokens (especially recurrently)

  Each cause produces a row with:
  - Cause label (FAILED, DEAD, GATE, CTX)
  - Task title
  - Workflow name
  - Current step
  - Cause-specific detail line
  - Drill target (Traces for failures/CTX, UoW page for gates/dead)
  """

  import Ecto.Query

  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{Project, StepExecution, Task, Workflow, WorkflowStep}

  @type cause :: :failed | :dead | :gate | :context_pressure

  @type attention_row :: %{
          id: String.t(),
          cause: cause(),
          task_id: binary(),
          task_title: String.t(),
          project_id: binary(),
          project_name: String.t(),
          workflow_name: String.t(),
          step_name: String.t(),
          detail: String.t(),
          triggered_at: DateTime.t()
        }

  @context_window_threshold 100_000

  @doc """
  Get all attention zone rows for a user's projects, ordered by recency.

  Returns a list of attention rows (one per UoW + cause combination), sorted by
  most recent trigger first.
  """
  @spec get_rows(binary() | nil) :: [attention_row()]
  def get_rows(project_id \\ nil) do
    [
      failed_runs(project_id),
      dead_orchestrator_runs(project_id),
      gates_awaiting_input(project_id),
      context_window_pressure(project_id)
    ]
    |> List.flatten()
    |> Enum.sort_by(& &1.triggered_at, {:desc, DateTime})
    |> Enum.uniq_by(&{&1.task_id, &1.cause})
  end

  @doc """
  Get failed runs: tasks with a step_execution that has status="failed".
  """
  @spec failed_runs(binary() | nil) :: [attention_row()]
  def failed_runs(project_id \\ nil) do
    base_query()
    |> where([se, _t, _w, _p, _ws], se.status == "failed")
    |> scope_query(project_id)
    |> Repo.all()
    |> Enum.map(&build_row(&1, :failed, fn row -> "step: #{row.step_name} (failed)" end))
  end

  @doc """
  Get dead-orchestrator runs: tasks in active step_executions where the
  orchestrator process is not alive, excluding human-intervention or explicit-wait steps.
  """
  @spec dead_orchestrator_runs(binary() | nil) :: [attention_row()]
  def dead_orchestrator_runs(_project_id \\ nil) do
    # For now, return empty. The actual detection of "orchestrator process not alive"
    # requires external state (e.g., checking a process registry or heartbeat table).
    # This is a placeholder for when that infrastructure exists.
    []
  end

  @doc """
  Get gates awaiting human input: tasks currently in wait_children step type.
  """
  @spec gates_awaiting_input(binary() | nil) :: [attention_row()]
  def gates_awaiting_input(project_id \\ nil) do
    base_query()
    |> where(
      [se, _t, _w, _p, ws],
      ws.step_type == "wait_children" and se.status == "pending"
    )
    |> scope_query(project_id)
    |> Repo.all()
    |> Enum.map(&build_row(&1, :gate, fn _row -> "awaiting your approval" end))
  end

  @doc """
  Get context-window pressure: step_executions with cumulative tokens >100k,
  especially those recurring (appearing multiple times for same task+step).
  """
  @spec context_window_pressure(binary() | nil) :: [attention_row()]
  def context_window_pressure(project_id \\ nil) do
    base_query()
    |> where(
      [se, _t, _w, _p, _ws],
      coalesce(se.input_tokens, 0) + coalesce(se.output_tokens, 0) >
        ^@context_window_threshold
    )
    |> select_merge([se], %{
      token_count: coalesce(se.input_tokens, 0) + coalesce(se.output_tokens, 0)
    })
    |> scope_query(project_id)
    |> Repo.all()
    |> Enum.map(fn row ->
      build_row(row, :context_pressure, fn r ->
        "step: #{r.step_name} (#{format_tokens(r.token_count)} tokens)"
      end)
    end)
  end

  defp base_query do
    from se in StepExecution,
      join: t in Task,
      on: se.task_id == t.id,
      join: w in Workflow,
      on: se.workflow_id == w.id,
      join: p in Project,
      on: se.project_id == p.id,
      join: ws in WorkflowStep,
      on: se.step_id == ws.id,
      distinct: true,
      select: %{
        task_id: t.id,
        task_title: t.title,
        workflow_name: w.name,
        step_name: ws.name,
        project_id: p.id,
        project_name: p.name,
        triggered_at: se.inserted_at
      }
  end

  defp scope_query(query, nil), do: query

  defp scope_query(query, project_id) when is_binary(project_id) do
    from [_se, _t, _w, p, _ws] in query, where: p.id == ^project_id
  end

  defp build_row(row, cause, detail_fn) do
    %{
      id: "attention-row-#{row.task_id}",
      cause: cause,
      task_id: row.task_id,
      task_title: row.task_title,
      project_id: row.project_id,
      project_name: row.project_name,
      workflow_name: row.workflow_name,
      step_name: row.step_name,
      detail: detail_fn.(row),
      triggered_at: row.triggered_at
    }
  end

  defp format_tokens(count) when count >= 1_000_000 do
    "#{Float.round(count / 1_000_000, 1)}M tok"
  end

  defp format_tokens(count) when count >= 1_000 do
    "#{Float.round(count / 1_000, 1)}k tok"
  end

  defp format_tokens(count) when is_integer(count), do: "#{count} tok"
end
