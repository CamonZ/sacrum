defmodule Sacrum.Chat.InferenceEvents do
  @moduledoc """
  Builds internal chat inference event payloads.
  """

  alias Sacrum.Chat.Inference
  alias Sacrum.Chat.Inference.Result
  alias Sacrum.Repo.Schemas.ChatMessage

  @completed "chat_inference.completed"
  @failed "chat_inference.failed"

  @spec completed_attrs(ChatMessage.t(), Result.t()) :: map()
  def completed_attrs(%ChatMessage{} = message, %Result{} = inference_result) do
    internal_event_attrs(@completed, %{
      "assistant_message_id" => message.id,
      "metadata" => inference_result.internal_metadata
    })
  end

  @spec failed_attrs(term()) :: map()
  def failed_attrs(reason) do
    internal_event_attrs(@failed, %{"error" => Inference.normalize_error(reason)})
  end

  @spec event_type(:completed | :failed) :: String.t()
  def event_type(:completed), do: @completed
  def event_type(:failed), do: @failed

  defp internal_event_attrs(event_type, payload) do
    %{
      event_type: event_type,
      visibility: :internal,
      public_payload: %{},
      internal_payload: payload
    }
  end
end
