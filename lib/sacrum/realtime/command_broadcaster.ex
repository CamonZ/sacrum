defmodule Sacrum.Realtime.CommandBroadcaster do
  @moduledoc """
  Sends transient execution commands to the assigned daemon. Project channels
  continue to carry client state projections, never execution commands.
  """

  alias Sacrum.Repo.Schemas.{Task, WorkflowStep}
  alias Sacrum.Repo.Schemas.WorkflowStep.Config

  @doc """
  Sends run_step for a started execution. The request comes from the
  execution's rendered config; only `verbose_daemon_logging` is read from the
  step.
  """
  @spec broadcast_run_step(map(), String.t() | nil) :: :ok | {:error, atom()}
  def broadcast_run_step(%{execution: execution} = data, daemon_id) do
    payload =
      %{
        id: execution.id,
        task_id: execution.task_id,
        project_id: execution.project_id,
        worktree: Task.workspace_worktree(data.task)
      }
      |> Map.merge(request_payload(execution.config))
      |> put_present(:output_schema, WorkflowStep.output_schema(execution))
      |> put_present(:verbose_daemon_logging, data.step.verbose_daemon_logging || nil)

    broadcast(daemon_id, "run_step", payload)
  end

  # structured_inference sends resolved `state` with `fields` as the output
  # schema; the provider harness maps both to its own request.
  defp request_payload(%Config.StructuredInference{} = config) do
    %{
      state: config.state,
      agent_config: %{"provider" => config.provider, "model" => config.model}
    }
  end

  defp request_payload(config) do
    %{
      prompt: (config && Map.get(config, :prompt)) || "",
      agent_config: config && Map.get(config, :agent_config)
    }
  end

  defp put_present(payload, _key, nil), do: payload
  defp put_present(payload, key, value), do: Map.put(payload, key, value)

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
