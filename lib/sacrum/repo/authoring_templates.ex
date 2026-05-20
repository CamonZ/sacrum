defmodule Sacrum.Repo.AuthoringTemplates do
  @moduledoc """
  Database operations for app-owned authoring templates.
  """

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.AuthoringTemplate

  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.AuthoringTemplate

  @spec get_by_classification_and_name(map() | keyword(), String.t()) ::
          {:ok, AuthoringTemplate.t()} | {:error, :not_found}
  def get_by_classification_and_name(filters, name) when is_binary(name) do
    get_by(conditions: [{:name, name} | classification_conditions!(filters)])
  end

  @spec insert(map() | Ecto.Changeset.t()) ::
          {:ok, AuthoringTemplate.t()} | {:error, Ecto.Changeset.t()}
  def insert(%Ecto.Changeset{} = changeset) do
    Repo.insert(changeset)
  end

  def insert(attrs) when is_map(attrs) do
    %AuthoringTemplate{}
    |> AuthoringTemplate.create_changeset(attrs)
    |> Repo.insert()
  end

  @spec list_by_classification(map() | keyword()) :: [AuthoringTemplate.t()]
  def list_by_classification(filters) do
    all(
      conditions: classification_conditions!(filters),
      order_by: [asc: :name]
    )
  end

  defp classification_conditions!(filters) do
    filter_map = normalize_filter_map!(filters)

    Enum.map(AuthoringTemplate.classification_fields(), fn key ->
      {key, fetch_filter!(filter_map, key)}
    end)
  end

  defp normalize_filter_map!(filters) when is_map(filters), do: filters

  defp normalize_filter_map!(filters) when is_list(filters) do
    if Keyword.keyword?(filters) do
      Map.new(filters)
    else
      raise ArgumentError, "classification filters must be a map or keyword list"
    end
  end

  defp normalize_filter_map!(_filters) do
    raise ArgumentError, "classification filters must be a map or keyword list"
  end

  defp fetch_filter!(filters, key) do
    case Map.fetch(filters, key) do
      {:ok, value} ->
        value

      :error ->
        case Map.fetch(filters, Atom.to_string(key)) do
          {:ok, value} -> value
          :error -> raise ArgumentError, "missing required classification filter #{key}"
        end
    end
  end
end
