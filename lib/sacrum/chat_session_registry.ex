defmodule Sacrum.ChatSessionRegistry do
  @moduledoc """
  Registry for supervised chat session runner processes.

  Chat sessions are registered by their persisted `chat_sessions.id` value so
  callers can avoid starting duplicate runner processes for the same session.
  """

  @spec via_tuple(String.t()) :: {:via, Registry, {module(), String.t()}}
  def via_tuple(chat_session_id) when is_binary(chat_session_id) do
    {:via, Registry, {__MODULE__, chat_session_id}}
  end

  @spec lookup(String.t()) :: [{pid(), term()}]
  def lookup(chat_session_id) when is_binary(chat_session_id) do
    Registry.lookup(__MODULE__, chat_session_id)
  end
end
