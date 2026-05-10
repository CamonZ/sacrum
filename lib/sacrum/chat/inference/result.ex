defmodule Sacrum.Chat.Inference.Result do
  @moduledoc """
  Normalized assistant inference result returned by Sacrum chat providers.

  Provider-specific response structs and raw HTTP payloads should be converted to
  this shape before crossing back into Sacrum chat persistence.
  """

  @type t :: %__MODULE__{
          content: String.t(),
          content_format: :plain | :markdown,
          public_metadata: map(),
          internal_metadata: map()
        }

  @enforce_keys [:content]
  defstruct content: nil,
            content_format: :markdown,
            public_metadata: %{},
            internal_metadata: %{}
end
