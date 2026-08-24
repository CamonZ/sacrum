defmodule Sacrum.Routing.Traverse do
  @moduledoc false

  @spec map_while([term()], (term(), non_neg_integer() -> {:ok, term()} | {:error, term()})) ::
          {:ok, [term()]} | {:error, term()}
  def map_while(items, fun) when is_list(items) and is_function(fun, 2) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, acc} ->
      case fun.(item, index) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec each_while([term()], (term(), non_neg_integer() -> :ok | {:error, term()})) ::
          :ok | {:error, term()}
  def each_while(items, fun) when is_list(items) and is_function(fun, 2) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {item, index}, :ok ->
      case fun.(item, index) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
