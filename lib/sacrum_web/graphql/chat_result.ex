defmodule SacrumWeb.Graphql.ChatResult do
  @moduledoc "Formats results for machine-scoped chat and review thread fields."

  alias Sacrum.Repo.WriteError

  @spec format(
          {:ok, map()} | {:error, :invalid_payload | :not_found | Ecto.Changeset.t()},
          String.t()
        ) :: {:ok, map()} | {:error, %{message: String.t(), code: String.t()}}
  def format({:ok, %{status: status} = write}, _resource) when is_atom(status),
    do: {:ok, %{write | status: Atom.to_string(status)}}

  def format({:ok, _} = result, _resource), do: result

  def format({:error, %Ecto.Changeset{} = changeset}, resource),
    do: format({:error, WriteError.from_changeset(changeset)}, resource)

  def format({:error, :invalid_payload}, resource),
    do: {:error, %{message: "Invalid #{resource} input", code: "invalid_payload"}}

  def format({:error, :not_found}, resource),
    do:
      {:error,
       %{message: "#{String.capitalize(resource)} or its scope was not found", code: "not_found"}}
end
