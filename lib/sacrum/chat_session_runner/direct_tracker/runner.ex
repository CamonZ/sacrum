defmodule Sacrum.ChatSessionRunner.DirectTracker.Runner do
  @moduledoc """
  Coordinates direct tracker execution from verified inference metadata.
  """

  alias Sacrum.Chat.{DirectTrackerOperationExecutor, Inference}
  alias Sacrum.ChatSessionRunner.DirectTracker.{Events, Operations}
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{ChatEvent, ChatSession}

  @spec execute(ChatSession.t(), Inference.Result.t(), map()) ::
          {:ok, [ChatEvent.t()]} | {:error, term()}
  def execute(
        %ChatSession{} = session,
        %Inference.Result{} = inference_result,
        extra_public_payload
      )
      when is_map(extra_public_payload) do
    with {:ok, operations} <- Operations.direct_tracker_operations(inference_result) do
      execute(session, operations, extra_public_payload)
    end
  end

  @spec execute(ChatSession.t(), [term()], map()) :: {:ok, [ChatEvent.t()]} | {:error, term()}
  def execute(%ChatSession{} = session, operations, extra_public_payload)
      when is_list(operations) and is_map(extra_public_payload) do
    Repo.transaction(fn ->
      case do_execute(operations, session, extra_public_payload) do
        {:ok, events} -> Enum.reverse(events)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec maybe_execute(ChatSession.t(), Inference.Result.t(), String.t(), String.t()) ::
          {:ok, [ChatEvent.t()]} | {:error, term()}
  def maybe_execute(
        %ChatSession{} = session,
        %Inference.Result{} = inference_result,
        assistant_message_id,
        turn_message_id
      )
      when is_binary(assistant_message_id) and is_binary(turn_message_id) do
    case Operations.direct_tracker_operations(inference_result) do
      {:error, :not_found} ->
        {:ok, []}

      {:ok, operations} ->
        execute(session, operations, %{
          "assistant_message_id" => assistant_message_id,
          "turn_message_id" => turn_message_id
        })

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec do_execute([term()], ChatSession.t(), map()) :: {:ok, [ChatEvent.t()]} | {:error, term()}
  defp do_execute(operations, %ChatSession{} = session, extra_public_payload) do
    Enum.reduce_while(operations, {:ok, []}, fn operation, {:ok, events} ->
      case execute_one(session, operation, extra_public_payload) do
        {:ok, event} -> {:cont, {:ok, [event | events]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec execute_one(ChatSession.t(), term(), map()) :: {:ok, ChatEvent.t()} | {:error, term()}
  defp execute_one(%ChatSession{} = session, operation, extra_public_payload) do
    with {:ok, result} <- DirectTrackerOperationExecutor.execute(operation) do
      Events.append_completed(session, operation, result, extra_public_payload)
    end
  end
end
