defmodule Sacrum.Repo.UuidPrefixResolver do
  @moduledoc """
  Resolves entities by 1-8 character hex UUID prefix against a scoped query.
  """

  import Ecto.Query
  alias Sacrum.Repo

  @hex_prefix_regex ~r/\A[0-9a-f]{1,8}\z/i

  @spec find_by_prefix(Ecto.Queryable.t(), String.t(), keyword()) ::
          {:ok, struct()}
          | {:error, :not_found | :invalid_prefix}
          | {:error, {:ambiguous, [String.t()]}}
  def find_by_prefix(query, prefix, opts \\ []) do
    if Regex.match?(@hex_prefix_regex, prefix) do
      query
      |> where(
        [q],
        fragment("left(?::text, ?)", q.id, ^String.length(prefix)) ==
          ^String.downcase(prefix)
      )
      |> limit(2)
      |> preload(^Keyword.get(opts, :preloads, []))
      |> Repo.all()
      |> case do
        [] -> {:error, :not_found}
        [entity] -> {:ok, entity}
        candidates -> {:error, {:ambiguous, Enum.map(candidates, & &1.id)}}
      end
    else
      {:error, :invalid_prefix}
    end
  end
end
