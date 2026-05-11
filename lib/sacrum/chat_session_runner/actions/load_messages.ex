defmodule Sacrum.ChatSessionRunner.Actions.LoadMessages do
  @moduledoc """
  Loads the persisted chat transcript and decides whether to invoke inference or
  resume from a previously persisted assistant message.
  """

  use Jido.Action,
    name: "sacrum_chat_session_load_messages",
    description: "Load chat transcript and route between inference and resume",
    category: "chat",
    tags: ["sacrum", "chat", "session", "load_messages"],
    vsn: "1.0.0",
    schema: [
      chat_session_id: [type: :string, required: true],
      engine_session_ref: [type: :string, required: true],
      inference_opts: [type: :any, default: []]
    ]

  alias Jido.Agent.Directive
  alias Sacrum.ChatSessionRunner.Actions
  alias Sacrum.ChatSessionRunner.Actions.Failure
  alias Sacrum.ChatSessionRunner.Pipeline
  alias Sacrum.ChatSessionRunner.Signals
  alias Sacrum.Repo.Schemas.{ChatMessage, ChatSession}

  @impl true
  def run(params, _context) do
    with {:ok, session} <- Pipeline.fetch_session(params.chat_session_id),
         {:continue, session} <- Pipeline.ensure_runnable(session),
         {:ok, messages} <- Pipeline.load_messages(session) do
      route_next(session, messages, params)
    else
      {:halt, _session, reason} -> Failure.halt(params, reason)
      {:error, reason} -> Failure.fail(params, reason)
    end
  end

  @spec route_next(ChatSession.t(), [ChatMessage.t()], map()) ::
          {:ok, map(), [Directive.Emit.t()]}
  defp route_next(session, messages, params) do
    {next_signal, route} =
      case Pipeline.lookup_assistant_message(session) do
        {:ok, _message} -> {Signals.resume_assistant(), :resume}
        {:error, :not_found} -> {Signals.invoke_inference(), :invoke_inference}
      end

    directive =
      Actions.emit(next_signal, %{
        chat_session_id: session.id,
        engine_session_ref: params.engine_session_ref,
        inference_opts: params.inference_opts
      })

    {:ok,
     %{
       step: :load_messages,
       chat_session_id: session.id,
       route: route,
       message_count: length(messages)
     }, [directive]}
  end
end
