defmodule Sacrum.Orchestrator.Routing.RouteAudit do
  @moduledoc """
  Canonical persisted shape for a local deterministic route decision.

  `context.route` is the audit record. `transition_result` and `handoff` on
  the StepExecution remain the destination and payload. Visit counting and
  restart recovery both read this same context shape.
  """

  import Ecto.Query

  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.StepExecution
  alias Sacrum.Routing.RouteContext

  @mode "deterministic"

  @doc """
  Builds the StepExecution context for a committed local route.
  """
  @spec context(map(), map(), map(), map()) :: map()
  def context(provenance, program, route_context, result) do
    %{
      "route" => %{
        "mode" => @mode,
        "source_execution_id" => provenance.source_execution.id,
        "config_version" => program.version,
        "matched_rule_id" => result.matched_rule_id,
        "used_default" => result.used_default,
        "context" => RouteContext.interpolation_context(route_context)
      }
    }
  end

  @doc """
  True when a StepExecution is a committed local deterministic route audit.
  """
  @spec deterministic?(term()) :: boolean()
  def deterministic?(%StepExecution{
        context: %{"route" => %{"mode" => @mode, "source_execution_id" => source_id}}
      })
      when is_binary(source_id),
      do: true

  def deterministic?(_execution), do: false

  @doc """
  Current-inclusive visit count for one task and route step.

  Only completed local route audits count. The first local decision is visit 1.
  """
  @spec visit_count(Sacrum.Repo.Schemas.Task.t(), String.t()) :: pos_integer()
  def visit_count(task, route_step_id) when is_binary(route_step_id) do
    completed_count =
      Repo.one(
        from(e in StepExecution,
          where:
            e.user_id == ^task.user_id and e.project_id == ^task.project_id and
              e.task_id == ^task.id and e.step_id == ^route_step_id and
              e.status == "completed" and
              fragment("?->'route'->>'mode' = ?", e.context, ^@mode),
          select: count(e.id)
        )
      )

    completed_count + 1
  end
end
