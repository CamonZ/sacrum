defmodule Sacrum.Chat.InferenceEvents do
  @moduledoc """
  Shared builders for persisted chat inference messages and internal events.
  """

  alias Sacrum.Chat.Inference
  alias Sacrum.Repo.Schemas.ChatMessage

  @inference_completed "chat_inference.completed"

  @spec assistant_message_attrs(Inference.Result.t(), keyword()) :: map()
  def assistant_message_attrs(%Inference.Result{} = inference_result, opts \\ []) do
    maybe_put_client_message_id(
      %{
        role: :assistant,
        content: inference_result.content,
        content_format: inference_result.content_format,
        metadata: inference_result.public_metadata
      },
      Keyword.get(opts, :client_message_id)
    )
  end

  @spec inference_completed_attrs(ChatMessage.t(), Inference.Result.t()) :: map()
  def inference_completed_attrs(%ChatMessage{} = message, %Inference.Result{} = inference_result) do
    build_inference_completed_attrs(message, %{
      "metadata" => inference_result.internal_metadata
    })
  end

  @spec resumed_inference_completed_attrs(ChatMessage.t()) :: map()
  def resumed_inference_completed_attrs(%ChatMessage{} = message) do
    build_inference_completed_attrs(message, %{
      "metadata" => %{},
      "resumed" => true
    })
  end

  @spec event_type(:inference_completed) :: String.t()
  def event_type(:inference_completed), do: @inference_completed

  defp build_inference_completed_attrs(%ChatMessage{} = message, internal_payload) do
    %{
      event_type: @inference_completed,
      visibility: :internal,
      public_payload: %{},
      internal_payload:
        Map.merge(
          %{"assistant_message_id" => message.id},
          Inference.scrub_secrets(internal_payload)
        )
    }
  end

  defp maybe_put_client_message_id(attrs, nil), do: attrs

  defp maybe_put_client_message_id(attrs, client_message_id),
    do: Map.put(attrs, :client_message_id, client_message_id)
end
