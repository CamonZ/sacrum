defmodule Sacrum.Orchestrator.ExecutionConfig do
  @moduledoc """
  Renders a workflow step's config into the config a `StepExecution` runs
  with: the same variant and fields, with templates filled in from the
  execution context. `llm_inference` renders its prompt; `structured_inference`
  resolves its state. Other variants are used as configured, and null-config
  step types stay null.
  """

  alias Sacrum.Orchestrator.PromptRenderer
  alias Sacrum.Repo.Schemas.WorkflowStep
  alias Sacrum.Repo.Schemas.WorkflowStep.Config
  alias Sacrum.Routing.HandoffTemplate

  @spec render(WorkflowStep.t(), map()) :: {:ok, Config.t()} | {:error, term()}
  def render(%WorkflowStep{config: %Config.LlmInference{} = config}, context) do
    with {:ok, prompt} <- PromptRenderer.render(config.prompt, context) do
      {:ok, %{config | prompt: prompt}}
    end
  end

  def render(%WorkflowStep{config: %Config.StructuredInference{} = config}, context) do
    with {:ok, %{"state" => state}} <-
           HandoffTemplate.resolve_config(%{"state" => config.state}, context, "$") do
      {:ok, %{config | state: state}}
    end
  end

  def render(%WorkflowStep{config: config}, _context), do: {:ok, config}
end
