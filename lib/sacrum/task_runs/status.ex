defmodule Sacrum.TaskRuns.Status do
  @moduledoc """
  Canonical status contract for durable TaskRun lifecycle state.

  TaskRun status answers what the automation run is doing now. StepExecution
  status answers what happened to one step attempt, so a failed attempt does not
  make the enclosing run failed until the run itself transitions to `:failed`.
  """

  @type t :: :queued | :executing | :waiting | :stopping | :stopped | :completed | :failed

  @values [:queued, :executing, :waiting, :stopping, :stopped, :completed, :failed]
  @active_statuses [:queued, :executing, :waiting, :stopping]
  @terminal_statuses [:stopped, :completed, :failed]
  @successful_statuses [:completed]
  @failed_statuses [:failed]
  @stoppable_statuses [:queued, :executing, :waiting]

  @spec values() :: [t()]
  def values, do: @values

  @spec active_statuses() :: [t()]
  def active_statuses, do: @active_statuses

  @spec terminal_statuses() :: [t()]
  def terminal_statuses, do: @terminal_statuses

  @spec active?(term()) :: boolean()
  def active?(status), do: status in @active_statuses

  @spec terminal?(term()) :: boolean()
  def terminal?(status), do: status in @terminal_statuses

  @spec successful?(term()) :: boolean()
  def successful?(status), do: status in @successful_statuses

  @spec failed?(term()) :: boolean()
  def failed?(status), do: status in @failed_statuses

  @spec stoppable?(term()) :: boolean()
  def stoppable?(status), do: status in @stoppable_statuses
end
