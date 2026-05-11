defmodule Sacrum.ChatSessionRunner.Actions.Intake do
  @moduledoc """
  Boots the chat-session run: verifies the session is runnable, marks it
  running, persists the intake status message, and emits the load-messages
  signal.
  """

  use Jido.Action,
    name: "sacrum_chat_session_intake",
    description: "Mark a chat session as running and persist the intake status message",
    category: "chat",
    tags: ["sacrum", "chat", "session", "intake"],
    vsn: "1.0.0",
    schema: [
      chat_session_id: [type: :string, required: true],
      engine_session_ref: [type: :string, required: true],
      inference_opts: [type: :any, default: []]
    ]

  alias Sacrum.ChatSessionRunner.Actions
  alias Sacrum.ChatSessionRunner.Actions.Failure
  alias Sacrum.ChatSessionRunner.Pipeline
  alias Sacrum.ChatSessionRunner.Signals

  @impl true
  def run(params, _context) do
    with {:ok, session} <- Pipeline.fetch_session(params.chat_session_id),
         {:continue, session} <- Pipeline.ensure_runnable(session),
         {:ok, session} <- Pipeline.intake(session, params.engine_session_ref) do
      directive =
        Actions.emit(Signals.load_messages(), %{
          chat_session_id: session.id,
          engine_session_ref: params.engine_session_ref,
          inference_opts: params.inference_opts
        })

      {:ok, %{step: :intake, chat_session_id: session.id}, [directive]}
    else
      {:halt, _session, reason} -> Failure.halt(params, reason)
      {:error, reason} -> Failure.fail(params, reason)
    end
  end
end
