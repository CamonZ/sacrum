defmodule Sacrum.ChatSessionRunner.Actions.MarkFailed do
  @moduledoc """
  Terminal failure handler. Persists a failed session checkpoint and stops the
  agent without leaking raw runtime details into public events.
  """

  use Jido.Action,
    name: "sacrum_chat_session_mark_failed",
    description: "Persist a failed chat-session checkpoint and stop the run",
    category: "chat",
    tags: ["sacrum", "chat", "session", "mark_failed"],
    vsn: "1.0.0",
    schema: [
      chat_session_id: [type: :string, required: true],
      reason: [type: :any, required: true]
    ]

  alias Sacrum.ChatSessionRunner.Pipeline

  @impl true
  def run(%{chat_session_id: chat_session_id, reason: reason}, _context) do
    Pipeline.mark_failed(chat_session_id, reason)

    {:ok,
     %{
       status: :failed,
       step: :mark_failed,
       chat_session_id: chat_session_id,
       error: reason
     }}
  end
end
