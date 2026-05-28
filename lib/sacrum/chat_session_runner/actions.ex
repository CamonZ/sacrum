defmodule Sacrum.ChatSessionRunner.Actions do
  @moduledoc """
  Signal helpers for the chat-session runner pipeline.

  Each durable step (intake, load messages, invoke inference, append/resume
  assistant, complete session, mark failed) is a Jido action under
  `Sacrum.ChatSessionRunner.Actions.*`. Actions emit the next signal as a
  directive so the AgentServer keeps coordinating the run without a private
  GenServer abstraction wrapping Jido.
  """

  alias Jido.Agent.Directive
  alias Jido.Signal
  alias Sacrum.ChatSessionRunner.Signals

  @doc """
  Build the initial run signal that boots the pipeline.
  """
  @spec run_signal(String.t(), String.t(), keyword()) :: Signal.t()
  def run_signal(chat_session_id, engine_session_ref, inference_opts)
      when is_binary(chat_session_id) and is_binary(engine_session_ref) and
             is_list(inference_opts) do
    Signal.new!(
      Signals.run(),
      %{
        chat_session_id: chat_session_id,
        engine_session_ref: engine_session_ref,
        inference_opts: inference_opts
      },
      source: Signals.source()
    )
  end

  @doc """
  Build a user-turn signal accepted by the session-owned runner.
  """
  @spec user_turn_signal(map()) :: Signal.t()
  def user_turn_signal(data) when is_map(data) do
    Signal.new!(Signals.user_turn(), data, source: Signals.source())
  end

  @doc """
  Build the crash-recovery hydration signal for a session-owned runner.
  """
  @spec hydrate_session_signal(String.t(), String.t(), keyword()) :: Signal.t()
  def hydrate_session_signal(chat_session_id, engine_session_ref, inference_opts)
      when is_binary(chat_session_id) and is_binary(engine_session_ref) and
             is_list(inference_opts) do
    Signal.new!(
      Signals.hydrate_session(),
      %{
        chat_session_id: chat_session_id,
        engine_session_ref: engine_session_ref,
        inference_opts: inference_opts
      },
      source: Signals.source()
    )
  end

  @doc false
  @spec emit(String.t(), map()) :: Directive.Emit.t()
  def emit(type, data) when is_binary(type) and is_map(data) do
    Directive.emit(Signal.new!(type, data, source: Signals.source()))
  end
end
