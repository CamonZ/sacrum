defmodule Sacrum.ChatSessionRunner.Actions.Failure do
  @moduledoc false

  alias Sacrum.ChatSessionRunner.Actions
  alias Sacrum.ChatSessionRunner.Signals

  @doc """
  Emit a mark-failed directive carrying the failure reason. Used by pipeline
  actions to recover from internal errors without exposing raw runtime details
  in public chat events.
  """
  @spec fail(map(), term()) :: {:ok, map(), [term()]}
  def fail(%{chat_session_id: chat_session_id}, reason) do
    directive =
      Actions.emit(Signals.mark_failed(), %{
        chat_session_id: chat_session_id,
        reason: reason
      })

    {:ok,
     %{
       step: :failure,
       chat_session_id: chat_session_id,
       error_recorded: true
     }, [directive]}
  end

  @doc """
  Treat a terminal session status as a no-op completion. Sets agent state to
  `:completed` so `await_completion` unblocks while recording the halt reason
  on `last_answer`.
  """
  @spec halt(map(), term()) :: {:ok, map()}
  def halt(%{chat_session_id: chat_session_id}, reason) do
    {:ok,
     %{
       status: :completed,
       step: :halt,
       chat_session_id: chat_session_id,
       last_answer: %{status: :noop, reason: reason}
     }}
  end
end
