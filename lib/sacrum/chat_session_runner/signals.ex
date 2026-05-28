defmodule Sacrum.ChatSessionRunner.Signals do
  @moduledoc """
  Signal type names and source URI for the chat session runner.

  These constants form the public boundary between the Jido AgentServer routing
  layer and the chat session runner pipeline actions. Each signal corresponds to
  one durable step in the session-first run loop.
  """

  @source "/sacrum/chat_session_runner"

  @user_turn "sacrum.chat_session.user_turn"
  @hydrate_session "sacrum.chat_session.hydrate_session"
  @run "sacrum.chat_session.run"
  @intake "sacrum.chat_session.intake"
  @load_messages "sacrum.chat_session.load_messages"
  @invoke_inference "sacrum.chat_session.invoke_inference"
  @verify_authoring "sacrum.chat_session.verify_authoring"
  @append_assistant "sacrum.chat_session.append_assistant"
  @resume_assistant "sacrum.chat_session.resume_assistant"
  @complete_session "sacrum.chat_session.complete_session"
  @mark_failed "sacrum.chat_session.mark_failed"
  @noop "sacrum.chat_session.noop"

  @spec source() :: String.t()
  def source, do: @source

  @spec user_turn() :: String.t()
  def user_turn, do: @user_turn

  @spec hydrate_session() :: String.t()
  def hydrate_session, do: @hydrate_session

  @spec run() :: String.t()
  def run, do: @run

  @spec intake() :: String.t()
  def intake, do: @intake

  @spec load_messages() :: String.t()
  def load_messages, do: @load_messages

  @spec invoke_inference() :: String.t()
  def invoke_inference, do: @invoke_inference

  @spec verify_authoring() :: String.t()
  def verify_authoring, do: @verify_authoring

  @spec append_assistant() :: String.t()
  def append_assistant, do: @append_assistant

  @spec resume_assistant() :: String.t()
  def resume_assistant, do: @resume_assistant

  @spec complete_session() :: String.t()
  def complete_session, do: @complete_session

  @spec mark_failed() :: String.t()
  def mark_failed, do: @mark_failed

  @spec noop() :: String.t()
  def noop, do: @noop

  @doc """
  All signal types the runner agent listens for.

  Used to make the routing table and tests share one source of truth.
  """
  @spec all() :: [String.t()]
  def all do
    [
      @user_turn,
      @hydrate_session,
      @run,
      @intake,
      @load_messages,
      @invoke_inference,
      @verify_authoring,
      @append_assistant,
      @resume_assistant,
      @complete_session,
      @mark_failed
    ]
  end
end
