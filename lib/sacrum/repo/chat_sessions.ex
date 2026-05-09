defmodule Sacrum.Repo.ChatSessions do
  @moduledoc """
  Database operations for V0 live chat sessions.
  """

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.ChatSession

  import Ecto.Query
  import Sacrum.Chat.Guards

  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.ChatSession

  @default_limit 50

  @spec insert(String.t(), String.t(), map()) ::
          {:ok, ChatSession.t()} | {:error, Ecto.Changeset.t()}
  def insert(user_id, project_id, attrs \\ %{})
      when is_user_project_scope(user_id, project_id) and is_attrs(attrs) do
    %ChatSession{user_id: user_id, project_id: project_id}
    |> ChatSession.create_changeset(attrs)
    |> Repo.insert()
  end

  @spec update(ChatSession.t(), map()) :: {:ok, ChatSession.t()} | {:error, Ecto.Changeset.t()}
  def update(%ChatSession{} = chat_session, attrs) when is_map(attrs) do
    chat_session
    |> ChatSession.update_changeset(attrs)
    |> Repo.update()
  end

  @spec list_for_project(String.t(), String.t(), keyword()) :: [ChatSession.t()]
  def list_for_project(user_id, project_id, opts \\ [])
      when is_user_project_scope(user_id, project_id) and is_options(opts) do
    ChatSession
    |> where([session], session.user_id == ^user_id and session.project_id == ^project_id)
    |> order_by([session], desc: session.inserted_at, desc: session.id)
    |> limit(^limit_option(opts))
    |> Repo.all()
  end

  defp limit_option(opts) do
    opts
    |> Keyword.get(:limit, @default_limit)
    |> min(@default_limit)
    |> max(1)
  end
end
