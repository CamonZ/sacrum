defmodule Sacrum.Chat.Inference.Provider do
  @moduledoc """
  Behaviour for chat inference providers.

  Providers receive normalized public chat messages and return a normalized
  assistant result. They must not leak provider-specific structs or secrets
  through the result's public metadata.
  """

  alias Sacrum.Chat.Inference.Result

  @type normalized_message :: %{
          required(:role) => String.t(),
          required(:content) => String.t()
        }

  @callback generate([normalized_message()], keyword()) :: {:ok, Result.t()} | {:error, term()}
end
