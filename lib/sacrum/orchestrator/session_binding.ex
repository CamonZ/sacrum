defmodule Sacrum.Orchestrator.SessionBinding do
  @moduledoc """
  Resolves an `llm_inference` step's named session against its TaskRun.

  The binding for name N in run R is the `native_session_id` of R's most
  recent completed execution with `session_name` N that reported one. There
  is no separate registry: executions already record which conversation they
  started or resumed. Other runs, other names, and unfinished or failed
  executions are never selected.
  """

  import Ecto.Query

  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{StepExecution, TaskRun, WorkflowStep}
  alias Sacrum.Repo.Schemas.WorkflowStep.Config

  @type resolution :: %{name: String.t() | nil, resume_session_id: String.t() | nil}
  @type error ::
          {:session_not_found, String.t()}
          | {:session_harness_mismatch,
             %{name: String.t(), bound: String.t() | nil, step: String.t() | nil}}

  @none %{name: nil, resume_session_id: nil}

  @doc """
  Returns the session name and resume id to dispatch the step with. Steps
  without a session config resolve to neither.
  """
  @spec resolve(TaskRun.t(), WorkflowStep.t(), Config.t()) ::
          {:ok, resolution()} | {:error, error()}
  def resolve(task_run, step, %Config.LlmInference{session: %{"name" => name, "mode" => mode}}) do
    case {mode, latest_binding(task_run.id, name)} do
      {"new", _binding} -> {:ok, %{name: name, resume_session_id: nil}}
      {"resume", nil} -> {:error, {:session_not_found, name}}
      {"resume_or_new", nil} -> {:ok, %{name: name, resume_session_id: nil}}
      {_resume, binding} -> resume(binding, name, step)
    end
  end

  def resolve(_task_run, _step, _config), do: {:ok, @none}

  defp resume(%{harness: harness, native_session_id: id}, name, %WorkflowStep{harness: harness}),
    do: {:ok, %{name: name, resume_session_id: id}}

  defp resume(%{harness: bound}, name, %WorkflowStep{harness: step}),
    do: {:error, {:session_harness_mismatch, %{name: name, bound: bound, step: step}}}

  defp latest_binding(task_run_id, name) do
    StepExecution
    |> where(
      [e],
      e.task_run_id == ^task_run_id and e.session_name == ^name and e.status == "completed" and
        not is_nil(e.native_session_id)
    )
    |> order_by([e], desc: e.inserted_at, desc: e.id)
    |> limit(1)
    |> select([e], %{native_session_id: e.native_session_id, harness: e.harness})
    |> Repo.one()
  end
end
