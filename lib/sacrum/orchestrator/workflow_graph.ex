defmodule Sacrum.Orchestrator.WorkflowGraph do
  @moduledoc """
  Pure helpers for loading and querying workflow graph structure.
  """

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.FSMData
  import Ecto.Query

  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{StepTransition, Task, WorkflowStep}
  alias Sacrum.Routing.RoutePredecessors

  @type route_predecessor :: %{
          transition_id: binary(),
          source_step_id: binary(),
          destination_step_id: binary(),
          user_id: binary(),
          project_id: binary(),
          workflow_id: binary(),
          output_schema: map() | nil
        }

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
  Loads persisted incoming step edges for a route step in its ownership scope.

  Each result keeps the edge and source-step identities so a predecessor
  contract error can identify the configuration that must be repaired.
  """
  @spec load_route_predecessors(WorkflowStep.t()) :: {:ok, [route_predecessor()]}
  def load_route_predecessors(%WorkflowStep{} = route_step) do
    predecessors =
      Repo.all(
        from(transition in StepTransition,
          join: source_step in WorkflowStep,
          on: source_step.id == transition.from_step_id,
          join: destination_step in WorkflowStep,
          on: destination_step.id == transition.to_step_id,
          where:
            transition.to_step_id == ^route_step.id and
              transition.user_id == ^route_step.user_id and
              transition.project_id == ^route_step.project_id and
              source_step.user_id == ^route_step.user_id and
              source_step.project_id == ^route_step.project_id and
              source_step.workflow_id == ^route_step.workflow_id and
              destination_step.user_id == ^route_step.user_id and
              destination_step.project_id == ^route_step.project_id and
              destination_step.workflow_id == ^route_step.workflow_id,
          order_by: [asc: transition.inserted_at, asc: transition.id],
          select: %{
            transition_id: transition.id,
            source_step_id: source_step.id,
            destination_step_id: destination_step.id,
            user_id: transition.user_id,
            project_id: transition.project_id,
            workflow_id: source_step.workflow_id,
            output_schema: source_step.output_schema
          }
        )
      )

    {:ok, predecessors}
  end

  @doc """
  Validates all incoming predecessor envelopes and returns their combined
  route-result domain alongside the source-aware edge list.
  """
  @spec validate_route_predecessors(WorkflowStep.t()) ::
          {:ok, %{predecessors: [route_predecessor()], type_environment: map()}}
          | {:error, RoutePredecessors.error()}
  def validate_route_predecessors(%WorkflowStep{} = route_step) do
    with {:ok, predecessors} <- load_route_predecessors(route_step),
         {:ok, type_environment} <- RoutePredecessors.derive_type_environment(predecessors) do
      {:ok, %{predecessors: predecessors, type_environment: type_environment}}
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
end
