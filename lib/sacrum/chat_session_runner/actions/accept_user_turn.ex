defmodule Sacrum.ChatSessionRunner.Actions.AcceptUserTurn do
  @moduledoc """
  Accepts a client user turn inside the session-owned runner.

  The accepted turn is persisted before any model or tracker work is invoked,
  so GraphQL and other ingress layers only deliver a signal and the AgentServer
  remains the sequencing boundary for live turns.
  """

  use Jido.Action,
    name: "sacrum_chat_session_accept_user_turn",
    description: "Persist an accepted live-chat user turn and continue the runner",
    category: "chat",
    tags: ["sacrum", "chat", "session", "user_turn"],
    vsn: "1.0.0",
    schema: [
      user_id: [type: :string, required: true],
      project_id: [type: :string, required: true],
      chat_session_id: [type: :string, required: true],
      message_id: [type: :string, required: true],
      engine_session_ref: [type: :string, required: true],
      content: [type: :string, required: true],
      content_format: [type: :string, default: "markdown"],
      client_message_id: [type: :string],
      metadata: [type: :map, default: %{}],
      inference_opts: [type: :any, default: []]
    ]

  alias Sacrum.Accounts.{ChatEvents, ChatMessages, ChatSessions}
  alias Sacrum.Chat.PublicEvents
  alias Sacrum.ChatSessionRunner.Actions
  alias Sacrum.ChatSessionRunner.Actions.Failure
  alias Sacrum.ChatSessionRunner.Pipeline
  alias Sacrum.ChatSessionRunner.Session.Turn
  alias Sacrum.ChatSessionRunner.Signals
  alias Sacrum.Repo

  @impl true
  def run(params, _context) do
    with {:ok, session} <-
           ChatSessions.get_session(params.user_id, params.project_id, params.chat_session_id),
         {:continue, session} <- ensure_accepts_user_turn(session),
         {:ok, messages} <- ChatMessages.list_for_session(session, include_private: true),
         defer_next_turn? = current_turn_in_flight?(session, messages),
         {:ok, message} <- persist_turn(session, params),
         {:ok, session} <- Pipeline.intake(session, params.engine_session_ref) do
      result = %{
        step: :accept_user_turn,
        chat_session_id: session.id,
        turn_message_id: message.id,
        deferred: defer_next_turn?
      }

      if defer_next_turn? do
        {:ok, result}
      else
        directive =
          Actions.emit(Signals.invoke_inference(), %{
            chat_session_id: session.id,
            engine_session_ref: params.engine_session_ref,
            inference_opts: params.inference_opts,
            turn_message_id: message.id
          })

        {:ok, result, [directive]}
      end
    else
      {:halt, _session, reason} -> Failure.halt(params, reason)
      {:error, reason} -> Failure.fail(params, reason)
    end
  end

  defp ensure_accepts_user_turn(%{status: status} = session) when status in [:completed, :failed],
    do: {:continue, session}

  defp ensure_accepts_user_turn(session), do: Pipeline.ensure_runnable(session)

  defp current_turn_in_flight?(session, messages) do
    case Turn.turn_message_id(messages) do
      turn_message_id when is_binary(turn_message_id) ->
        match?({:error, :not_found}, Pipeline.lookup_assistant_message(session, turn_message_id))

      nil ->
        false
    end
  end

  defp persist_turn(session, params) do
    Repo.transaction(fn ->
      attrs =
        %{
          id: params.message_id,
          role: :user,
          content: params.content,
          content_format: params.content_format,
          client_message_id: Map.get(params, :client_message_id),
          metadata: Map.get(params, :metadata, %{})
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      with {:ok, message} <- ChatMessages.append_to_session(session, attrs),
           {:ok, _event} <-
             ChatEvents.append_to_session(session, PublicEvents.message_created_attrs(message)) do
        message
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end
end
