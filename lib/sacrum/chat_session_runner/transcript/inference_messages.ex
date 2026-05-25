defmodule Sacrum.ChatSessionRunner.Transcript.InferenceMessages do
  @moduledoc """
  Shapes persisted chat messages into the model input transcript.

  The runner sends user turns plus the assistant response tied to each turn,
  preserving persisted turn order while excluding runner status messages.
  """

  alias Sacrum.ChatSessionRunner.Session.Turn
  alias Sacrum.Repo.Schemas.ChatMessage

  @spec conversation_messages_for_inference([ChatMessage.t()]) :: [ChatMessage.t()]
  def conversation_messages_for_inference(messages) when is_list(messages) do
    assistant_by_turn =
      messages
      |> Enum.filter(&(&1.role == :assistant))
      |> Map.new(fn message -> {Turn.turn_message_id_from_assistant(message), message} end)
      |> Map.delete(nil)

    messages
    |> Enum.filter(&(&1.role == :user))
    |> Enum.flat_map(fn user_message ->
      case Map.fetch(assistant_by_turn, user_message.id) do
        {:ok, assistant_message} -> [user_message, assistant_message]
        :error -> [user_message]
      end
    end)
  end
end
