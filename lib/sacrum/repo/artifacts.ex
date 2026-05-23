defmodule Sacrum.Repo.Artifacts do
  @moduledoc """
  Database operations for project-scoped artifacts.
  """

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.Artifact

  import Ecto.Query
  import Sacrum.Chat.Guards

  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.Artifact
  alias Sacrum.Repo.Schemas.ArtifactLink
  alias Sacrum.Repo.Schemas.Project

  @default_limit 50
  @public_redaction_states ~w(not_needed redacted)

  @spec insert(String.t(), String.t(), map()) ::
          {:ok, Artifact.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def insert(user_id, project_id, attrs \\ %{})
      when is_user_project_scope(user_id, project_id) and is_attrs(attrs) do
    if project_exists?(user_id, project_id) do
      %Artifact{user_id: user_id, project_id: project_id}
      |> Artifact.create_changeset(attrs)
      |> Repo.insert()
    else
      {:error, :not_found}
    end
  end

  @spec update(Artifact.t(), map()) :: {:ok, Artifact.t()} | {:error, Ecto.Changeset.t()}
  def update(%Artifact{} = artifact, attrs) when is_attrs(attrs) do
    artifact
    |> Artifact.update_changeset(attrs)
    |> Repo.update()
  end

  @spec list_public_for_project(String.t(), String.t(), keyword()) :: [Artifact.t()]
  def list_public_for_project(user_id, project_id, opts \\ [])
      when is_user_project_scope(user_id, project_id) and is_options(opts) do
    Artifact
    |> where_public_in_scope(user_id, project_id)
    |> apply_public_artifact_order()
    |> apply_limit(opts)
    |> Repo.all()
  end

  @spec list_public_for_subject(String.t(), String.t(), String.t(), String.t(), keyword()) :: [
          Artifact.t()
        ]
  def list_public_for_subject(user_id, project_id, subject_type, subject_id, opts \\ [])
      when is_user_project_scope(user_id, project_id) and is_binary(subject_type) and
             is_binary(subject_id) and is_options(opts) do
    Artifact
    |> join(:inner, [artifact], link in ArtifactLink, on: link.artifact_id == artifact.id)
    |> where_public_in_scope(user_id, project_id)
    |> where_subject_link_in_scope(user_id, project_id, subject_type, subject_id)
    |> apply_public_artifact_order()
    |> apply_limit(opts)
    |> Repo.all()
  end

  defp where_public_in_scope(query, user_id, project_id) do
    where(
      query,
      [artifact],
      artifact.user_id == ^user_id and artifact.project_id == ^project_id and
        artifact.visibility == "public" and artifact.redaction_state in ^@public_redaction_states
    )
  end

  defp where_subject_link_in_scope(query, user_id, project_id, subject_type, subject_id) do
    where(
      query,
      [_artifact, link],
      link.user_id == ^user_id and link.project_id == ^project_id and
        link.subject_type == ^subject_type and link.subject_id == ^subject_id
    )
  end

  defp apply_public_artifact_order(query) do
    order_by(query, [artifact], desc: artifact.inserted_at, desc: artifact.id)
  end

  defp apply_limit(query, opts) do
    limit(query, ^limit_option(opts))
  end

  defp project_exists?(user_id, project_id) do
    Project
    |> where([project], project.id == ^project_id and project.user_id == ^user_id)
    |> Repo.exists?()
  end

  defp limit_option(opts) do
    opts
    |> Keyword.get(:limit, @default_limit)
    |> min(@default_limit)
    |> max(1)
  end
end
