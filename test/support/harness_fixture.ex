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

  @doc "A streaming text event for one item; `item_id: nil` omits the correlation."
  def text(event_id, semantics, text, opts \\ []) do
    correlation =
      case Keyword.get(opts, :item_id, "item-1") do
        nil -> %{}
        item_id -> %{item_id: item_id}
      end

    content =
      Jason.encode!(%{
        version: 1,
        event_id: event_id,
        stream_id: Keyword.get(opts, :stream_id, "fixture"),
        sequence: Keyword.get(opts, :sequence, 1),
        timestamp: "2026-10-04T00:00:00Z",
        semantics: semantics,
        type: "text",
        correlation: correlation,
        data: %{text: text}
      })

    %{logical_key: "harness:" <> event_id, content: content}
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
