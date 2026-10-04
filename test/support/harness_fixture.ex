defmodule Sacrum.HarnessFixture do
  @moduledoc false

  def attrs(text) do
    id = Base.encode16(:crypto.hash(:sha256, text), case: :lower)
    %{logical_key: "harness:" <> id, content: content(text)}
  end

  def content(text) do
    id = Base.encode16(:crypto.hash(:sha256, text), case: :lower)

    Jason.encode!(%{
      version: 1,
      event_id: id,
      stream_id: "fixture",
      sequence: 1,
      timestamp: "2026-07-17T00:00:00Z",
      semantics: "snapshot",
      type: "text",
      correlation: %{},
      data: %{text: text}
    })
  end

  def with_event(attrs) do
    case Map.fetch(attrs, :content) do
      {:ok, text} ->
        Map.merge(attrs, attrs(text))

      :error ->
        text = Map.fetch!(attrs, "content")

        Enum.reduce(attrs(text), attrs, fn {key, value}, acc ->
          Map.put(acc, Atom.to_string(key), value)
        end)
    end
  end
end
