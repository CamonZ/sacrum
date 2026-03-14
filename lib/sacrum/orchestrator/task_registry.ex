defmodule Sacrum.Orchestrator.TaskRegistry do
  @moduledoc """
  Global registry for TaskOrchestrator gen_statem processes.

  Allows looking up and sending messages to a TaskOrchestrator by task_id.
  Used with :via tuple in TaskOrchestrator.start_link/1.

  Example:
    {:via, Registry, {Sacrum.Orchestrator.TaskRegistry, task_id}}
  """

  @spec child_spec :: {module(), keyword()}
  def child_spec do
    {Registry, keys: :unique, name: __MODULE__}
  end
end
