defmodule SacrumWeb.Graphql.Types.DaemonTypes do
  @moduledoc """
  Owner-authenticated daemon management surface.

  Resolvers stay thin and delegate to Accounts; lifecycle mechanics live in
  the repository layer. Responses carry only safe metadata: no token hashes,
  plaintext credentials or raw credential records are ever serialized
  (`DaemonCredential.safe_metadata/1` projection), and the removed
  server-advertised endpoint fields stay absent.
  """

  use Absinthe.Schema.Notation
  alias Sacrum.Accounts.Daemons
  alias Sacrum.Repo.Schemas.Daemon

  object :daemon do
    field :id, non_null(:uuid4)
    field :status, non_null(:string)
    # Nullable for legacy/unnamed rows; displayName is the non-null label.
    field :name, :string

    field :display_name, non_null(:string) do
      description("Name when set, with a stable short-ID fallback for legacy rows.")

      resolve(fn %Daemon{} = daemon, _, _ -> {:ok, Daemon.display_name(daemon)} end)
    end

    field :enrolled_at, :datetime
    field :removed_at, :datetime
    field :inserted_at, :datetime
    field :updated_at, :datetime
  end

  object :daemon_credential_metadata do
    field :id, non_null(:uuid4)
    field :credential_kind, non_null(:string)
    field :status, non_null(:string)
    field :expires_at, non_null(:datetime)
    field :consumed_at, :datetime
    field :revoked_at, :datetime
    field :inserted_at, :datetime
    field :updated_at, :datetime
  end

  object :daemon_enrollment_metadata do
    field :daemon_id, non_null(:uuid4)
    field :status, non_null(:string)
    field :enrolled_at, :datetime
    field :credentials, non_null(list_of(non_null(:daemon_credential_metadata)))
  end

  object :daemon_bootstrap do
    field :daemon, non_null(:daemon)
    field :enrollment_token, non_null(:string)
    field :expires_at, non_null(:datetime)
  end

  object :daemon_queries do
    field :daemons, non_null(list_of(non_null(:daemon))) do
      # Active fleet view: tombstones disappear from the list only after a
      # successful unregister; they remain readable through daemon(id).
      resolve(fn _, %{context: %{current_user: user}} -> {:ok, Daemons.list_fleet(user.id)} end)
    end

    field :daemon, :daemon do
      arg(:id, non_null(:uuid4))

      resolve(fn %{id: id}, %{context: %{current_user: user}} ->
        case Daemons.get_by(user.id, conditions: [id: id]) do
          {:ok, daemon} -> {:ok, daemon}
          {:error, :not_found} -> {:ok, nil}
        end
      end)
    end

    field :daemon_enrollment_metadata, :daemon_enrollment_metadata do
      arg(:id, non_null(:uuid4))

      resolve(fn %{id: id}, %{context: %{current_user: user}} ->
        case Daemons.enrollment(user.id, id) do
          {:ok, metadata} -> {:ok, metadata}
          {:error, :not_found} -> {:ok, nil}
        end
      end)
    end
  end

  object :daemon_mutations do
    field :create_daemon, non_null(:daemon_bootstrap) do
      arg(:name, :string)

      resolve(fn args, %{context: %{current_user: user}} ->
        with {:ok, daemon, token, credential} <- Daemons.create_bootstrap(user.id, args) do
          {:ok, %{daemon: daemon, enrollment_token: token, expires_at: credential.expires_at}}
        end
      end)
    end

    field :rename_daemon, :daemon do
      arg(:id, non_null(:uuid4))
      arg(:name, :string)

      resolve(fn %{id: id, name: name}, %{context: %{current_user: user}} ->
        translate_error(Daemons.rename(user.id, id, %{name: name}))
      end)
    end

    field :revoke_daemon, :daemon do
      arg(:id, non_null(:uuid4))

      resolve(fn %{id: id}, %{context: %{current_user: user}} ->
        translate_error(Daemons.revoke(user.id, id))
      end)
    end

    field :unregister_daemon, :daemon do
      arg(:id, non_null(:uuid4))

      resolve(fn %{id: id}, %{context: %{current_user: user}} ->
        translate_error(Daemons.unregister(user.id, id))
      end)
    end

    field :rotate_daemon_credentials, non_null(:daemon_bootstrap) do
      arg(:id, non_null(:uuid4))

      resolve(fn %{id: id}, %{context: %{current_user: user}} ->
        with {:ok, daemon, token, credential} <- Daemons.rotate_bootstrap(user.id, id) do
          {:ok, %{daemon: daemon, enrollment_token: token, expires_at: credential.expires_at}}
        end
      end)
    end
  end

  # Structured, non-disclosing domain errors: unknown and foreign identities
  # share one message; changesets flow to ChangesetErrors middleware unchanged.
  defp translate_error({:ok, _} = ok), do: ok

  defp translate_error({:error, :not_found}),
    do: {:error, "daemon not found"}

  defp translate_error({:error, :terminal_state}),
    do: {:error, "daemon is in a terminal state (revoked or removed)"}

  defp translate_error({:error, :active_work}),
    do: {:error, "daemon has an active session; disconnect it before unregistering"}

  defp translate_error({:error, :ownership_unknown}),
    do:
      {:error,
       "daemon has enrollment history and cannot be unregistered until work ownership is established"}

  defp translate_error(other), do: other
end
