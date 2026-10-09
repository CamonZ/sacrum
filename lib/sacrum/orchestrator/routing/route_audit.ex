defmodule Sacrum.Orchestrator.Routing.RouteAudit do
  @moduledoc """
  Canonical persisted shape for a local deterministic route decision.

  `context.route` is the audit record. `transition_result` and `handoff` on
  the StepExecution remain the destination and payload; `context.route.session`
  is the selected decision's session directive, if any. Visit counting and
  restart recovery both read this same context shape.
  """

  import Ecto.Query

  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.StepExecution
  alias Sacrum.Routing.{RouteConfig, RouteContext}

  @mode "deterministic"

  @doc """
  Builds the StepExecution context for a committed local route.
  """
  @spec context(map(), map(), map(), map()) :: map()
  def context(provenance, program, route_context, result) do
    route =
      %{
        "mode" => @mode,
        "source_execution_id" => provenance.source_execution.id,
        "config_version" => program.version,
        "matched_rule_id" => result.matched_rule_id,
        "used_default" => result.used_default,
        "context" => audit_context(program, route_context)
      }

    case session(result) do
      nil -> %{"route" => route}
      session -> %{"route" => Map.put(route, "session", session)}
    end
  end

  @doc """
  The session directive the destination is dispatched with, as recorded in
  `context.route.session`: `%{"mode" => "new"}` or
  `%{"mode" => "resume" | "fork", "step_id" => id}`, where an omitted
  `step_id` names the destination step.
  """
  @spec session(map()) :: map() | nil
  def session(%{session: %{mode: :new}}), do: %{"mode" => "new"}

  def session(%{session: %{mode: mode, step_id: step_id}, transition: transition}) do
    %{"mode" => Atom.to_string(mode), "step_id" => step_id || transition.step_id}
  end

  def session(_result), do: nil

  # Predecessor output is not copied wholesale: the audit keeps the task,
  # visit count, and only the output values the rules and handoff templates
  # referenced.
  defp audit_context(program, context) do
    acc =
      context
      |> RouteContext.interpolation_context()
      |> Map.put("previous_output", %{})

    (RouteConfig.output_references(program) ++ RouteConfig.handoff_output_references(program))
    |> Enum.uniq()
    |> Enum.reduce(
      acc,
      fn reference, snapshot ->
        case RouteContext.fetch(context, reference) do
          {:ok, value} -> put_in(snapshot, access_path(reference), value)
          :missing -> snapshot
        end
      end
    )
  end

  defp access_path(reference),
    do: reference |> String.split(".") |> Enum.map(&Access.key(&1, %{}))

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
