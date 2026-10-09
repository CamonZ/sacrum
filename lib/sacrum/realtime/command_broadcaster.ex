defmodule Sacrum.Realtime.CommandBroadcaster do
  @moduledoc """
  Sends transient execution commands to the assigned daemon. Project channels
  continue to carry client state projections, never execution commands.
  """

  alias Sacrum.Repo.Schemas.Task
  alias Sacrum.Repo.Schemas.WorkflowStep.Config

  @doc """
  Sends run_step for a started execution. The request comes from the
  execution's rendered config. Inference reads `harness` from the step;
  execute omits it. `verbose_daemon_logging` is read from the step, and
  `session` from the execution's pinned conversation fields.
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
      |> put_harness(execution.config, data.step)
      |> put_present(:verbose_daemon_logging, data.step.verbose_daemon_logging || nil)
      |> put_present(:session, session_payload(execution))

    broadcast(daemon_id, "run_step", payload)
  end

  # structured_inference sends resolved `state` with its `questions`; the
  # provider harness builds its request from both and returns the provider's
  # answers unchanged.
  defp request_payload(%Config.StructuredInference{} = config) do
    %{
      state: config.state,
      questions: config.questions,
      agent_config: %{"provider" => config.provider, "model" => config.model}
    }
  end

  defp request_payload(%Config.Execute{} = config) do
    %{
      step_type: "execute",
      version: config.version,
      script: config.script,
      context: config.context,
      output_schema: config.output_schema
    }
  end

  defp request_payload(config) do
    put_present(
      %{
        prompt: (config && Map.get(config, :prompt)) || "",
        agent_config: config && Map.get(config, :agent_config)
      },
      :output_schema,
      config && Map.get(config, :output_schema)
    )
  end

  # Every llm_inference execution is rooted in a conversation; the daemon
  # starts it, resumes the pinned native id, or forks from it. `resume_id`
  # carries the source id for both resume and fork.
  defp session_payload(execution) do
    case {Map.get(execution, :conversation_root_execution_id),
          Map.get(execution, :forked_from_execution_id), Map.get(execution, :resume_session_id)} do
      {nil, _forked_from, _resume_id} -> nil
      {_root, nil, nil} -> %{mode: "new"}
      {_root, nil, resume_id} -> %{mode: "resume", resume_id: resume_id}
      {_root, _forked_from, resume_id} -> %{mode: "fork", resume_id: resume_id}
    end
  end

  defp put_present(payload, _key, nil), do: payload
  defp put_present(payload, key, value), do: Map.put(payload, key, value)

  defp put_harness(payload, %Config.Execute{}, _step), do: payload

  defp put_harness(payload, _config, step),
    do: put_present(payload, :harness, Map.get(step, :harness))

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
