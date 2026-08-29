defmodule Sacrum.Orchestrator.WorkflowGraph do
  @moduledoc """
  Load and query the workflow graph a TaskRun walks.

  `load_validated_workflow_and_graph/2` is the single load/validate boundary
  for TaskRun entry (new, resumed, and inter-workflow hops): authorize the
  workflow, load one support snapshot, prove that workflow's routes against
  it, and derive the FSM lookup maps from the same snapshot.
  """

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.FSMData
  alias Sacrum.Repo.RouteValidation
  alias Sacrum.Repo.Schemas.Task
  alias Sacrum.Repo.Schemas.WorkflowStep
  alias Sacrum.Routing.RouteValidator

  @doc """
  Load a workflow and the step/transition maps the FSM walks.

  The maps come from the snapshot that was just validated, not from a
  second topology load. A hop to a different workflow is a new call.
  """
  @spec load_validated_workflow_and_graph(binary(), Task.t()) ::
          {:ok, any(), map(), map()} | {:error, term()}
  def load_validated_workflow_and_graph(user_id, task) do
    with {:ok, workflow} <-
           Accounts.Workflows.get_by(user_id, conditions: [id: task.workflow_id]),
         {:ok, snapshot} <- RouteValidation.load_snapshot(workflow.id),
         :ok <- RouteValidator.validate_snapshot(snapshot, [workflow.id]) do
      {steps, transitions} = owner_graph(snapshot, workflow.id)
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

  @doc """
  Validate the destination of a transition when it is a stop step.

  Stop steps are run boundaries and therefore must have exactly one outgoing
  transition so that the next TaskRun has an unambiguous continuation.
  """
  @spec validate_stop_destination(FSMData.t(), binary()) ::
          :ok | {:error, :no_outgoing_transitions | :multiple_outgoing_transitions}
  def validate_stop_destination(data, step_id) do
    case Map.get(data.steps, step_id) do
      %WorkflowStep{step_type: :stop} ->
        data
        |> get_outgoing_transitions(step_id)
        |> select_single_transition()
        |> case do
          {:ok, _next_step_id} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _step ->
        :ok
    end
  end

  defp owner_graph(snapshot, owner_id) do
    steps =
      snapshot.steps
      |> Enum.filter(fn {_id, step} -> step.workflow_id == owner_id end)
      |> Map.new()

    transitions =
      Map.new(steps, fn {id, _step} ->
        {id, Enum.map(Map.get(snapshot.step_edges, id, []), & &1.to_step_id)}
      end)

    {steps, transitions}
  end
end
