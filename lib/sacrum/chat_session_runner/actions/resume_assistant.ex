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
      inference_opts: [type: :any, default: []],
      turn_message_id: [type: :string]
    ]

  alias Sacrum.ChatSessionRunner.Actions
  alias Sacrum.ChatSessionRunner.Actions.Failure
  alias Sacrum.ChatSessionRunner.Pipeline
  alias Sacrum.ChatSessionRunner.Signals

  @impl true
  def run(params, _context) do
    with {:ok, session} <- Pipeline.fetch_session(params.chat_session_id),
         {:continue, session} <- Pipeline.ensure_runnable(session),
         {:ok, directive} <- resume_or_continue(session, params) do
      {:ok, %{step: :resume_assistant, chat_session_id: session.id}, [directive]}
    else
      {:halt, _session, reason} -> Failure.halt(params, reason)
      {:error, reason} -> Failure.fail(params, reason)
    end
  end

  defp resume_or_continue(session, params) do
    case Pipeline.lookup_assistant_message(session) do
      {:ok, message} ->
        with {:ok, _session, _message} <- Pipeline.resume_assistant_message(session, message) do
          {:ok, complete_session_directive(session, params)}
        end

      {:error, :not_found} ->
        continue_direct_tracker_turn(session, params)
    end
  end

  defp continue_direct_tracker_turn(session, params) do
    with {:ok, session, result} <-
           Pipeline.resume_direct_tracker_continuation(
             session,
             params.inference_opts,
             Map.get(params, :turn_message_id)
           ) do
      {:ok, append_assistant_directive(session, result, params)}
    end
  end

  defp append_assistant_directive(session, result, params) do
    Actions.emit(Signals.append_assistant(), %{
      chat_session_id: session.id,
      engine_session_ref: params.engine_session_ref,
      inference_opts: params.inference_opts,
      turn_message_id: Map.get(params, :turn_message_id),
      inference_result: result
    })
  end

  defp complete_session_directive(session, params) do
    Actions.emit(Signals.complete_session(), %{
      chat_session_id: session.id,
      engine_session_ref: params.engine_session_ref,
      inference_opts: params.inference_opts
    })
  end
end
