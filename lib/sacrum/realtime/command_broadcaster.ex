defmodule Sacrum.Realtime.CommandBroadcaster do
  @moduledoc """
  Sends transient execution commands to the assigned daemon. Project channels
  continue to carry client state projections, never execution commands.
  """

  alias Sacrum.Repo.Schemas.Task

  @spec broadcast_run_step(map(), String.t() | nil) :: :ok | {:error, atom()}
  def broadcast_run_step(data, daemon_id) do
    payload = %{
      id: data.execution.id,
      task_id: data.execution.task_id,
      project_id: data.execution.project_id,
      prompt: data.rendered_prompt,
      agent_config: data.step.agent_config,
      worktree: Task.workspace_worktree(data.task)
    }

    payload =
      case data.step.output_schema do
        nil -> payload
        schema -> Map.put(payload, :output_schema, schema)
      end

    payload =
      case data.step.verbose_daemon_logging do
        true -> Map.put(payload, :verbose_daemon_logging, true)
        _ -> payload
      end

    broadcast(daemon_id, "run_step", payload)
  end

  @spec broadcast_cancel_step(map(), String.t() | nil) :: :ok | {:error, atom()}
  def broadcast_cancel_step(execution, daemon_id) do
    broadcast(daemon_id, "cancel_step", %{
      step_execution_id: execution.id,
      task_id: execution.task_id,
      project_id: execution.project_id
    })
  end

  defp broadcast(nil, _event, _payload), do: {:error, :workspace_required}

  defp broadcast(daemon_id, event, payload) when is_binary(daemon_id) do
    SacrumWeb.Endpoint.broadcast("daemon:#{daemon_id}", event, payload)
  end
end
