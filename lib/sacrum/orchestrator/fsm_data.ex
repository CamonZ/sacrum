defmodule Sacrum.Orchestrator.FSMData do
  @moduledoc """
  Struct holding the TaskOrchestrator FSM's working data. Defined as a struct
  (not a plain map) so dialyzer can verify `%{data | key: value}` updates
  across the modules that participate in the FSM.
  """

  alias Sacrum.Repo.Schemas.{Task, Workflow, WorkflowStep}

  @enforce_keys [:user_id, :task, :project_id]
  defstruct [
    :user_id,
    :task,
    :task_run_id,
    :project_id,
    :workflow,
    :current_execution_id,
    :slot_id,
    :pending_handoff,
    steps: %{},
    transitions: %{},
    subscribed: false,
    run_retry_attempt: 0
  ]

  @type t :: %__MODULE__{
          user_id: binary(),
          task: Task.t(),
          task_run_id: binary() | nil,
          project_id: binary(),
          workflow: Workflow.t() | nil,
          steps: %{optional(binary()) => WorkflowStep.t()},
          transitions: %{optional(binary()) => [binary()]},
          current_execution_id: binary() | nil,
          slot_id: integer() | nil,
          pending_handoff: map() | nil,
          subscribed: boolean(),
          run_retry_attempt: non_neg_integer()
        }
end
