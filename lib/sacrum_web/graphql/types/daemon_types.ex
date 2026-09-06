defmodule SacrumWeb.Graphql.Types.DaemonTypes do
  use Absinthe.Schema.Notation
  alias Sacrum.Accounts.Daemons

  object :daemon do
    field :id, non_null(:uuid4)
    field :status, non_null(:string)
    field :inserted_at, :datetime
    field :updated_at, :datetime
  end

  object :daemon_bootstrap do
    field :daemon, non_null(:daemon)
    field :enrollment_token, non_null(:string)
    field :expires_at, non_null(:datetime)
  end

  object :daemon_queries do
    field :daemons, non_null(list_of(non_null(:daemon))) do
      resolve(fn _, %{context: %{current_user: user}} -> {:ok, Daemons.list_by(user.id)} end)
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
  end

  object :daemon_mutations do
    field :create_daemon, non_null(:daemon_bootstrap) do
      resolve(fn args, %{context: %{current_user: user}} ->
        with {:ok, daemon, token, credential} <- Daemons.create_bootstrap(user.id, args) do
          {:ok, %{daemon: daemon, enrollment_token: token, expires_at: credential.expires_at}}
        end
      end)
    end

    field :revoke_daemon, :daemon do
      arg(:id, non_null(:uuid4))

      resolve(fn %{id: id}, %{context: %{current_user: user}} ->
        Daemons.revoke(user.id, id)
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
end
