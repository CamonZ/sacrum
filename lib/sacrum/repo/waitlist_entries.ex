defmodule Sacrum.Repo.WaitlistEntries do
  @moduledoc """
  CRUD operations for waitlist entries.

  ## Error Contract

  - `create/1` returns `{:ok, entry}` or `{:error, changeset}`
    - On duplicate email, returns `{:error, changeset}` with unique_constraint error
  - `get/1` returns `{:ok, entry}` or `{:error, :not_found}`
  - `all/0` returns `[entry]`
  """

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.WaitlistEntry

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.WaitlistEntry

  @spec create(map()) :: {:ok, WaitlistEntry.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %WaitlistEntry{}
    |> WaitlistEntry.create_changeset(attrs)
    |> Repo.insert()
  end

  defoverridable create: 1
end
