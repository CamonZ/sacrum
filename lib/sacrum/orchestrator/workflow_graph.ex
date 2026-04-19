defmodule Sacrum.Orchestrator.WorkflowGraph do
  @moduledoc """
  Pure helpers for loading and querying workflow graph structure.
  """

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.FSMData
  alias Sacrum.Repo.Schemas.{Task, WorkflowStep}

  @doc """
  Load a workflow and build step/transition lookup maps.

  Returns `{:ok, workflow, steps, transitions}` where `steps` maps
  `step_id -> WorkflowStep` and `transitions` maps `step_id -> [to_step_ids]`.
  """
  @spec load_workflow_and_graph(binary(), Task.t()) ::
          {:ok, any(), map(), map()} | {:error, term()}
  def load_workflow_and_graph(user_id, task) do
    with {:ok, workflow} <-
           Accounts.Workflows.get_by(user_id,
             conditions: [id: task.workflow_id],
             preloads: [workflow_steps: :transitions]
           ) do
      steps = Map.new(workflow.workflow_steps, &{&1.id, &1})

      transitions =
        Map.new(workflow.workflow_steps, fn step ->
          {step.id, Enum.map(step.transitions, & &1.to_step_id)}
        end)

      {:ok, workflow, steps, transitions}
    end
  end

  @doc """
  Get the current step from the FSM data cache.

  Returns `{:ok, step}` or `{:error, :no_current_step | :step_not_found}`.
  """
  @spec get_current_step(FSMData.t()) ::
          {:ok, WorkflowStep.t()} | {:error, atom()}
  def get_current_step(%{task: %{current_step_id: nil}}), do: {:error, :no_current_step}

  def get_current_step(%{task: %{current_step_id: step_id}, steps: steps}) do
    case Map.fetch(steps, step_id) do
      {:ok, step} -> {:ok, step}
      :error -> {:error, :step_not_found}
    end
  end

  @doc """
  Get outgoing transitions for a step. Returns a list of destination step IDs.
  """
  @spec get_outgoing_transitions(FSMData.t(), binary()) :: [binary()]
  def get_outgoing_transitions(data, from_step_id) do
    Map.get(data.transitions, from_step_id, [])
  end

  @doc """
  Select the single destination from a list of transitions.
  Returns error for zero or multiple.
  """
  @spec select_single_transition([binary()]) ::
          {:ok, binary()} | {:error, :no_outgoing_transitions | :multiple_outgoing_transitions}
  def select_single_transition([next_step_id]), do: {:ok, next_step_id}
  def select_single_transition([]), do: {:error, :no_outgoing_transitions}
  def select_single_transition(_multiple), do: {:error, :multiple_outgoing_transitions}
end
