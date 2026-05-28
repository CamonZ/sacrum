defmodule Sacrum.ChatSessionRunner.Actions.CompleteSession do
  @moduledoc """
  Records per-turn chat completion and returns the agent to the idle state.
  """

  use Jido.Action,
    name: "sacrum_chat_session_complete",
    description: "Record completion for the current chat session turn",
    category: "chat",
    tags: ["sacrum", "chat", "session", "complete_session"],
    vsn: "1.0.0",
    schema: [
      chat_session_id: [type: :string, required: true],
      engine_session_ref: [type: :string, required: true],
      turn_message_id: [type: :string],
      inference_opts: [type: :any, default: []]
    ]

  alias Sacrum.ChatSessionRunner.{Actions, Signals}
  alias Sacrum.ChatSessionRunner.Actions.Failure
  alias Sacrum.ChatSessionRunner.Pipeline

  @impl true
  def run(params, context) do
    with {:ok, session} <- Pipeline.fetch_session(params.chat_session_id),
         {:continue, session} <- Pipeline.ensure_runnable(session),
         {:ok, completed_session} <-
           Pipeline.complete_session(session, Map.get(params, :turn_message_id)) do
      maybe_continue_next_turn(completed_session, params, context)
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

  defp maybe_continue_next_turn(session, params, context) do
    if Pipeline.pending_user_turn_after?(session, Map.get(params, :turn_message_id)) do
      directive =
        Actions.emit(Signals.intake(), %{
          chat_session_id: session.id,
          engine_session_ref: params.engine_session_ref,
          inference_opts: params.inference_opts
        })

      {:ok,
       %{
         step: :complete_session,
         chat_session_id: session.id,
         pending_turn: true,
         last_answer: %{session: session}
       }, [directive]}
    else
      complete_idle(session, context)
    end
  end

  defp complete_idle(session, context) do
    result = %{
      status: :idle,
      activity: :turn_completed,
      step: :complete_session,
      chat_session_id: session.id,
      last_answer: %{session: session},
      queued_user_turn_signal: nil
    }

    case get_in(context, [:state, :queued_user_turn_signal]) do
      %Jido.Signal{} = signal -> {:ok, result, [Actions.emit(signal)]}
      _signal -> {:ok, result}
    end
  end
end
