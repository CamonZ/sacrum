defmodule Sacrum.ChatSessionRunner.Actions.CompleteSession do
  @moduledoc """
  Transitions the chat session to completed and flips agent state to the
  terminal `:completed` status so `Jido.AgentServer.await_completion/2`
  unblocks.
  """

  use Jido.Action,
    name: "sacrum_chat_session_complete",
    description: "Mark a chat session as completed and end the run",
    category: "chat",
    tags: ["sacrum", "chat", "session", "complete_session"],
    vsn: "1.0.0",
    schema: [
      chat_session_id: [type: :string, required: true],
      engine_session_ref: [type: :string, required: true],
      inference_opts: [type: :any, default: []]
    ]

  alias Sacrum.ChatSessionRunner.Actions.Failure
  alias Sacrum.ChatSessionRunner.Pipeline

  @impl true
  def run(params, _context) do
    with {:ok, session} <- Pipeline.fetch_session(params.chat_session_id),
         {:continue, session} <- Pipeline.ensure_runnable(session),
         {:ok, completed_session} <- Pipeline.complete_session(session) do
      {:ok,
       %{
         status: :completed,
         step: :complete_session,
         chat_session_id: completed_session.id,
         last_answer: %{session: completed_session}
       }}
    else
      {:halt, session, reason} ->
        {:ok,
         %{
           status: :completed,
           step: :complete_session,
           chat_session_id: session.id,
           last_answer: %{session: session, status: :noop, reason: reason}
         }}

      {:error, reason} ->
        Failure.fail(params, reason)
    end
  end
end
