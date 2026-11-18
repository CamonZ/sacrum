defmodule Sacrum.ReviewThreads.Projection do
  @moduledoc "Shared GraphQL and CDC projection of a review-thread row."

  alias Sacrum.Repo.Schemas.ReviewThread
  alias Sacrum.ReviewThreads.Payload

  @payload_fields Enum.map(Payload.fields(), &{Atom.to_string(&1), &1})

  @spec entry(ReviewThread.t()) :: map()
  def entry(%ReviewThread{} = thread) do
    %{
      thread_id: thread.id,
      project_id: thread.project_id,
      installation_id: thread.installation_id,
      revision: thread.revision,
      updated_at: utc_usec(thread.updated_at),
      payload: Map.new(@payload_fields, fn {key, field} -> {key, value(thread, field)} end)
    }
  end

  defp utc_usec(%DateTime{microsecond: {microsecond, _}} = datetime),
    do: %{datetime | microsecond: {microsecond, 6}}

  defp value(thread, field) when field in [:side, :home_kind, :status, :origin_kind] do
    Keyword.fetch!(Ecto.Enum.mappings(ReviewThread, field), Map.fetch!(thread, field))
  end

  defp value(thread, field), do: Map.fetch!(thread, field)
end
