defmodule Sacrum.Realtime.CommandBroadcaster do
  @moduledoc """
  Sends imperative ProjectChannel commands to daemon clients.

  Default-client GUI state is projected from committed rows by
  `Sacrum.Realtime.Cdc.Projector`; this module is intentionally limited to
  daemon commands that are not CDC projections.
  """

  alias SacrumWeb.ProjectChannel

  require Logger

  @doc """
  Broadcast a `run_step` command with step execution and step definition data.
  """
  @spec broadcast_run_step(map(), String.t()) :: :ok | {:error, term()}
  def broadcast_run_step(data, project_id) when is_map(data) and is_binary(project_id) do
    Logger.info("[CommandBroadcast] run_step for project #{project_id}")
    ProjectChannel.broadcast_run_step(project_id, data)
  end

  @doc """
  Broadcast a `cancel_step` command with step execution and task identifiers.
  """
  @spec broadcast_cancel_step(struct() | map(), String.t()) :: :ok | {:error, term()}
  def broadcast_cancel_step(execution, project_id) when is_binary(project_id) do
    Logger.info("[CommandBroadcast] cancel_step for project #{project_id}")

    ProjectChannel.broadcast_cancel_step(project_id, %{
      step_execution_id: execution.id,
      task_id: execution.task_id
    })
  end
end
