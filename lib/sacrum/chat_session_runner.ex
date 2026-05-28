defmodule Sacrum.ChatSessionRunner do
  @moduledoc """
  Jido AgentServer-backed runtime for one persisted chat session assistant turn.

  Each durable step (intake, load messages, invoke inference, append assistant,
  resume assistant, complete session) is a distinct Jido action under
  `Sacrum.ChatSessionRunner.Actions.*`. Actions consume validated signal
  payloads and emit the next signal as a `Jido.Agent.Directive.Emit` directive,
  so the AgentServer is the single coordination boundary — Sacrum is not
  wrapping Jido in a second ad hoc runner abstraction.

  Sacrum still owns durable state: `ChatSession`, `ChatMessage`, `ChatEvent`,
  and the `engine_session_ref` mapping live in Postgres. The Jido agent
  carries only the run identifiers in its ephemeral state. Normal turn
  completion returns the runner to `:idle` so it can accept the next user turn;
  terminal statuses are reserved for cancellation, deletion, shutdown, and
  unrecoverable lifecycle failures.
  """

  alias Sacrum.ChatSessionRunner.Signals

  use Jido.Agent,
    name: "sacrum_chat_session_runner",
    description: "Runs one persisted Sacrum chat session assistant turn",
    category: "chat",
    tags: ["sacrum", "chat", "session"],
    vsn: "1.0.0",
    schema: [
      status: [type: :atom, default: :idle],
      chat_session_id: [type: :string],
      engine_session_ref: [type: :string],
      inference_opts: [type: :any, default: []],
      queued_user_turn_signal: [type: :any]
    ],
    signal_routes: [
      {Signals.user_turn(), Sacrum.ChatSessionRunner.Actions.AcceptUserTurn},
      {Signals.hydrate_session(), Sacrum.ChatSessionRunner.Actions.HydrateSession},
      {Signals.run(), Sacrum.ChatSessionRunner.Actions.Intake},
      {Signals.intake(), Sacrum.ChatSessionRunner.Actions.Intake},
      {Signals.load_messages(), Sacrum.ChatSessionRunner.Actions.LoadMessages},
      {Signals.invoke_inference(), Sacrum.ChatSessionRunner.Actions.InvokeInference},
      {Signals.verify_authoring(), Sacrum.ChatSessionRunner.Actions.VerifyAuthoringIntent},
      {Signals.append_assistant(), Sacrum.ChatSessionRunner.Actions.AppendAssistant},
      {Signals.resume_assistant(), Sacrum.ChatSessionRunner.Actions.ResumeAssistant},
      {Signals.complete_session(), Sacrum.ChatSessionRunner.Actions.CompleteSession},
      {Signals.mark_failed(), Sacrum.ChatSessionRunner.Actions.MarkFailed}
    ]

  require Logger

  alias Sacrum.Chat.Inference
  alias Sacrum.ChatSessionRunner.Actions
  alias Sacrum.ChatSessionRunner.Actions.InvokeInference

  @engine_session_ref_prefix "jido_agent_server:"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    chat_session_id = Keyword.fetch!(opts, :chat_session_id)
    inference_opts = Keyword.get(opts, :inference_opts, [])
    engine_session_ref = agent_id(chat_session_id)

    agent_opts = [
      agent: __MODULE__,
      id: engine_session_ref,
      initial_state: %{
        status: :idle,
        chat_session_id: chat_session_id,
        engine_session_ref: engine_session_ref,
        inference_opts: inference_opts,
        queued_user_turn_signal: nil
      },
      register_global: false,
      name: Sacrum.ChatSessionRegistry.via_tuple(chat_session_id)
    ]

    initial_signal =
      Keyword.get(opts, :initial_signal) ||
        Actions.hydrate_session_signal(chat_session_id, engine_session_ref, inference_opts)

    with {:ok, pid} <- Jido.AgentServer.start_link(agent_opts),
         :ok <- Jido.AgentServer.cast(pid, initial_signal) do
      {:ok, pid}
    else
      {:error, reason} = error ->
        Logger.error("[ChatSessionRunner:#{chat_session_id}] failed to start: #{inspect(reason)}")
        error
    end
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    chat_session_id = Keyword.fetch!(opts, :chat_session_id)

    %{
      id: {__MODULE__, chat_session_id},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :transient,
      shutdown: 5000
    }
  end

  @spec agent_id(String.t()) :: String.t()
  def agent_id(chat_session_id) when is_binary(chat_session_id) do
    @engine_session_ref_prefix <> chat_session_id
  end

  @impl true
  def on_before_cmd(agent, {InvokeInference, params}) when is_map(params) do
    inference_opts = Map.get(params, :inference_opts, Map.get(params, "inference_opts", []))
    timeout = Inference.timeout(inference_opts)
    {:ok, agent, {InvokeInference, params, %{}, [timeout: timeout]}}
  end

  def on_before_cmd(agent, action), do: {:ok, agent, action}
end
