defmodule Sacrum.Orchestrator.SessionBinding do
  @moduledoc """
  Resolves how an `llm_inference` execution enters a provider conversation.

  The route decision that led to the step carries the directive (see
  `RouteAudit.session/1`); entering without one starts a new conversation.

  A conversation is the set of a TaskRun's executions sharing a
  `conversation_root_execution_id`: a new or forked execution is its own
  root, and a resumed execution copies its source's root. Resume and fork
  name a step: its conversation is the one its latest completed execution
  belongs to, and the source turn is that conversation's latest completed
  execution with a `native_session_id`, whichever step added it. There is no
  separate registry, and other runs or failed executions are never selected.

  A retry continues exactly as its failed attempt did, from the same source
  turn (see `retry/3`).
  """

  import Ecto.Query

  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{StepExecution, TaskRun, WorkflowStep}

  @type resolution :: %{
          resume_session_id: String.t() | nil,
          conversation_root_execution_id: Ecto.UUID.t() | nil,
          forked_from_execution_id: Ecto.UUID.t() | nil
        }
  @type error ::
          {:session_not_found, Ecto.UUID.t()}
          | {:session_harness_mismatch,
             %{step_id: Ecto.UUID.t(), bound: String.t() | nil, step: String.t() | nil}}

  @none %{
    resume_session_id: nil,
    conversation_root_execution_id: nil,
    forked_from_execution_id: nil
  }

  @doc """
  Returns the conversation fields for execution `execution_id` of `step`.
  Steps other than `llm_inference` have none.
  """
  @spec resolve(TaskRun.t(), WorkflowStep.t(), map() | nil, Ecto.UUID.t()) ::
          {:ok, resolution()} | {:error, error()}
  def resolve(task_run, %WorkflowStep{step_type: :llm_inference} = step, directive, execution_id) do
    case directive do
      %{"mode" => mode, "step_id" => source_step_id} when mode in ["resume", "fork"] ->
        continue(task_run, step, mode, source_step_id, execution_id)

      _new ->
        {:ok, %{@none | conversation_root_execution_id: execution_id}}
    end
  end

  def resolve(_task_run, _step, _directive, _execution_id), do: {:ok, @none}

  defp continue(task_run, step, mode, source_step_id, execution_id) do
    case latest_turn(task_run.id, source_step_id) do
      nil ->
        {:error, {:session_not_found, source_step_id}}

      %{harness: harness} = turn when harness == step.harness ->
        {:ok, continuation(mode, turn, execution_id)}

      %{harness: bound} ->
        {:error,
         {:session_harness_mismatch, %{step_id: source_step_id, bound: bound, step: step.harness}}}
    end
  end

  defp continuation("resume", turn, _execution_id) do
    %{
      @none
      | resume_session_id: turn.native_session_id,
        conversation_root_execution_id: turn.root
    }
  end

  defp continuation("fork", turn, execution_id) do
    %{
      resume_session_id: turn.native_session_id,
      conversation_root_execution_id: execution_id,
      forked_from_execution_id: turn.id
    }
  end

  @doc """
  Returns the conversation fields for execution `execution_id` retrying
  `failed`: the same pinned `resume_session_id`, staying in a resumed
  conversation, and rooted at itself when the failed attempt was a new or
  forked one.
  """
  @spec retry(WorkflowStep.t(), StepExecution.t(), Ecto.UUID.t()) :: resolution()
  def retry(%WorkflowStep{step_type: :llm_inference}, failed, execution_id),
    do: retry_resolution(failed, execution_id)

  def retry(_step, _failed, _execution_id), do: @none

  # An attempt recorded before conversations were tracked starts a new one.
  defp retry_resolution(%StepExecution{conversation_root_execution_id: nil}, execution_id),
    do: %{@none | conversation_root_execution_id: execution_id}

  defp retry_resolution(
         %StepExecution{id: id, conversation_root_execution_id: id} = failed,
         execution_id
       ) do
    %{
      resume_session_id: failed.resume_session_id,
      conversation_root_execution_id: execution_id,
      forked_from_execution_id: failed.forked_from_execution_id
    }
  end

  defp retry_resolution(%StepExecution{} = failed, _execution_id) do
    %{
      @none
      | resume_session_id: failed.resume_session_id,
        conversation_root_execution_id: failed.conversation_root_execution_id
    }
  end

  # The step's latest completed execution picks the conversation even when it
  # reported no native id, so an older conversation is never resumed instead.
  defp latest_turn(task_run_id, step_id) do
    root =
      task_run_id
      |> completed()
      |> where([e], e.step_id == ^step_id)
      |> limit(1)
      |> select([e], e.conversation_root_execution_id)

    task_run_id
    |> completed()
    |> where([e], not is_nil(e.native_session_id))
    |> where([e], e.conversation_root_execution_id in subquery(root))
    |> limit(1)
    |> select([e], %{
      id: e.id,
      root: e.conversation_root_execution_id,
      native_session_id: e.native_session_id,
      harness: e.harness
    })
    |> Repo.one()
  end

  defp completed(task_run_id) do
    StepExecution
    |> where(
      [e],
      e.task_run_id == ^task_run_id and e.status == "completed" and
        not is_nil(e.conversation_root_execution_id)
    )
    |> order_by([e], desc: e.inserted_at, desc: e.id)
  end
end
