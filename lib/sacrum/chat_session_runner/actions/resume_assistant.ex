defmodule Sacrum.ChatSessionRunner.Actions.ResumeAssistant do
  @moduledoc """
  Re-emits public/internal events for an already-persisted assistant message
  and emits the complete-session signal without calling inference again.
  """

  use Jido.Action,
    name: "sacrum_chat_session_resume_assistant",
    description: "Resume from a persisted assistant message without re-invoking inference",
    category: "chat",
    tags: ["sacrum", "chat", "session", "resume_assistant"],
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
         {:ok, message} <- Pipeline.lookup_assistant_message(session),
         {:ok, _session, _message} <- Pipeline.resume_assistant_message(session, message) do
      directive =
        Actions.emit(Signals.complete_session(), %{
          chat_session_id: session.id,
          engine_session_ref: params.engine_session_ref,
          inference_opts: params.inference_opts
        })

      {:ok, %{step: :resume_assistant, chat_session_id: session.id}, [directive]}
    else
      {:halt, _session, reason} -> Failure.halt(params, reason)
      {:error, :not_found} -> Failure.fail(params, :assistant_message_missing_for_resume)
      {:error, reason} -> Failure.fail(params, reason)
    end
  end
end
