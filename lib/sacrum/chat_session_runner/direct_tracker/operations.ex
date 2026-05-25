defmodule Sacrum.ChatSessionRunner.DirectTracker.Operations do
  @moduledoc """
  Owns direct tracker metadata inspection and operation deserialization.
  """

  alias Sacrum.Chat.{DirectTrackerOperationResolver, Inference}

  @spec direct_tracker_metadata?(Inference.Result.t()) :: boolean()
  def direct_tracker_metadata?(%Inference.Result{} = result) do
    metadata = direct_tracker_metadata(result)

    is_map(Map.get(metadata, "resolved_direct_tracker_operation")) or
      is_list(Map.get(metadata, "resolved_direct_tracker_operations")) or
      is_map(Map.get(metadata, "direct_tracker_operation_rejected"))
  end

  @spec direct_tracker_operations(Inference.Result.t()) :: {:ok, [term()]} | {:error, term()}
  def direct_tracker_operations(%Inference.Result{} = result) do
    metadata = direct_tracker_metadata(result)

    case {Map.get(metadata, "resolved_direct_tracker_operations"),
          Map.get(metadata, "resolved_direct_tracker_operation")} do
      {nil, nil} ->
        {:error, :not_found}

      {nil, %{} = serialized} ->
        with {:ok, operation} <- DirectTrackerOperationResolver.deserialize_resolution(serialized) do
          {:ok, [operation]}
        end

      {list, nil} when is_list(list) ->
        DirectTrackerOperationResolver.deserialize_resolutions(list)

      {_list, _single} ->
        {:error, :invalid_direct_tracker_operation}
    end
  end

  @spec direct_tracker_metadata(Inference.Result.t()) :: map()
  def direct_tracker_metadata(%Inference.Result{internal_metadata: metadata})
      when is_map(metadata),
      do: metadata

  def direct_tracker_metadata(%Inference.Result{}), do: %{}
end
