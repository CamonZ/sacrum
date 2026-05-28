defmodule Sacrum.ChatSessionSupervisor do
  @moduledoc """
  Dynamic supervisor for reusable chat session runners.
  """

  use DynamicSupervisor

  alias Sacrum.ChatSessionRunner.Actions

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec start_runner(String.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_runner(chat_session_id, opts \\ [])
      when is_binary(chat_session_id) and is_list(opts) do
    child_opts = Keyword.put(opts, :chat_session_id, chat_session_id)
    DynamicSupervisor.start_child(__MODULE__, {Sacrum.ChatSessionRunner, child_opts})
  end

  @spec start_or_cast_user_turn(String.t(), Jido.Signal.t(), keyword()) ::
          DynamicSupervisor.on_start_child() | {:error, term()}
  def start_or_cast_user_turn(chat_session_id, signal, opts \\ [])
      when is_binary(chat_session_id) and is_list(opts) do
    case Sacrum.ChatSessionRegistry.lookup(chat_session_id) do
      [{pid, _}] ->
        case Jido.AgentServer.cast(pid, signal) do
          :ok -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end

      [] ->
        inference_opts =
          Keyword.get(opts, :inference_opts, Map.get(signal.data, :inference_opts, []))

        engine_session_ref = Sacrum.ChatSessionRunner.agent_id(chat_session_id)

        initial_signal =
          Actions.hydrate_session_signal(chat_session_id, engine_session_ref, inference_opts,
            queued_user_turn_signal: signal
          )

        start_runner(chat_session_id, Keyword.put(opts, :initial_signal, initial_signal))
    end
  end

  @spec terminate_runner(String.t()) :: :ok | {:error, :not_found}
  def terminate_runner(chat_session_id) when is_binary(chat_session_id) do
    case Sacrum.ChatSessionRegistry.lookup(chat_session_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> {:error, :not_found}
    end
  end
end
