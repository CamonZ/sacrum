defmodule Sacrum.Repo.DaemonCredentials do
  @moduledoc "Database operations for daemon enrollment credentials."

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.DaemonCredential

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.DaemonCredential

  @doc "Returns all active credentials for a daemon, newest first."
  @spec list_active_for_daemon(String.t()) :: [DaemonCredential.t()]
  def list_active_for_daemon(daemon_id) when is_binary(daemon_id) do
    Repo.all(
      from credential in DaemonCredential,
        where: credential.daemon_id == ^daemon_id and credential.status == "active",
        order_by: [desc: credential.inserted_at]
    )
  end
end
