defmodule SacrumWeb.StepExecutionJSON do
  alias Sacrum.Repo.Schemas.StepExecution

  def index(%{executions: executions}) do
    %{data: for(execution <- executions, do: data(execution))}
  end

  def show(%{execution: execution}) do
    %{data: data(execution)}
  end

  defp data(%StepExecution{} = e) do
    %{
      id: e.id,
      task_id: e.task_id,
      workflow_id: e.workflow_id,
      step_name: e.step_name,
      status: e.status,
      context: e.context,
      prompt: e.prompt,
      output: e.output,
      transition_result: e.transition_result,
      model: e.model,
      model_provider: e.model_provider,
      input_tokens: e.input_tokens,
      output_tokens: e.output_tokens,
      cost: e.cost,
      duration_ms: e.duration_ms,
      inserted_at: e.inserted_at,
      updated_at: e.updated_at
    }
  end
end
