defmodule Sacrum.Repo.Types.JsonContent do
  @moduledoc """
  A JSON string, object, or array stored as-is in a jsonb document.
  """

  use Ecto.Type

  @impl true
  def type, do: :map

  @impl true
  def cast(value) when is_binary(value) or is_map(value) or is_list(value), do: {:ok, value}
  def cast(_value), do: {:error, message: "must be a string, object, or array"}

  @impl true
  def load(value) when is_binary(value) or is_map(value) or is_list(value), do: {:ok, value}
  def load(_value), do: :error

  @impl true
  def dump(value) when is_binary(value) or is_map(value) or is_list(value), do: {:ok, value}
  def dump(_value), do: :error
end
