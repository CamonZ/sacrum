defmodule Sacrum.Orchestrator.ExecutionConfig do
  @moduledoc """
  Renders a workflow step's config into the config a `StepExecution` runs
  with: the same variant and fields, with templates filled in from the
  execution context. `llm_inference` renders its prompt; `human_input` its
  question, keeping its role verbatim; `structured_inference` resolves its state. `execute` strictly
  renders its script and snapshots the complete canonical context for
  daemon-owned variable binding. Other variants are used as configured, and
  null-config step types stay null.
  """

  alias Sacrum.Orchestrator.{PromptRenderer, ScriptRenderer}
  alias Sacrum.Repo.Schemas.WorkflowStep
  alias Sacrum.Repo.Schemas.WorkflowStep.Config
  alias Sacrum.Routing.HandoffTemplate

  @spec render(WorkflowStep.t(), map()) :: {:ok, Config.t()} | {:error, term()}
  def render(%WorkflowStep{config: %Config.LlmInference{} = config}, context) do
    with {:ok, prompt} <- PromptRenderer.render(config.prompt, context) do
      {:ok, %{config | prompt: prompt}}
    end
  end

  def render(%WorkflowStep{config: %Config.HumanInput{question: nil} = config}, _context),
    do: {:ok, config}

  def render(%WorkflowStep{config: %Config.HumanInput{} = config}, context) do
    with {:ok, question} <- PromptRenderer.render(config.question, context) do
      {:ok, %{config | question: question}}
    end
  end

  def render(%WorkflowStep{config: %Config.StructuredInference{} = config}, context) do
    with {:ok, %{"state" => state}} <-
           HandoffTemplate.resolve_config(%{"state" => config.state}, context, "$") do
      {:ok, %{config | state: state}}
    end
  end

  def render(%WorkflowStep{config: %Config.Execute{} = config}, context) do
    with :ok <- Config.Execute.validate_context(context),
         {:ok, script} <- ScriptRenderer.render(config.script, context) do
      {:ok, %{config | context: context, script: script}}
    end
  end

  def render(%WorkflowStep{config: config}, _context), do: {:ok, config}
end
