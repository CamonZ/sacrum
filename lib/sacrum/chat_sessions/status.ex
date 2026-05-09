defmodule Sacrum.ChatSessions.Status do
  @moduledoc """
  Canonical status contract for live chat session lifecycle state.

  The V0 chat persistence spine is session-first. These values answer what the
  live chat session is doing without implying anything about TaskRun or
  StepExecution state.
  """

  @type t :: :queued | :running | :waiting | :cancelling | :cancelled | :completed | :failed

  @values [:queued, :running, :waiting, :cancelling, :cancelled, :completed, :failed]
  @active_statuses [:queued, :running, :waiting, :cancelling]
  @terminal_statuses [:cancelled, :completed, :failed]
  @successful_statuses [:completed]
  @failed_statuses [:failed]
  @stoppable_statuses [:queued, :running, :waiting]

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

  @spec wire_value(t() | String.t() | nil) :: String.t() | nil
  def wire_value(status) when is_atom(status), do: Atom.to_string(status)
  def wire_value(status), do: status
end
