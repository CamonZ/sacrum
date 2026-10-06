defmodule Sacrum.Repo.Artifacts do
  @moduledoc """
  Database operations for project-scoped artifacts.
  """

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.Artifact

  import Ecto.Query

  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.Artifact
  alias Sacrum.Repo.Schemas.ArtifactLink
  alias Sacrum.Repo.Schemas.Project

  defguardp is_user_project_scope(user_id, project_id)
            when is_binary(user_id) and is_binary(project_id)

  defguardp is_attrs(attrs) when is_map(attrs)

  @spec get_in_scope(String.t(), String.t()) :: {:ok, Artifact.t()} | {:error, :not_found}
  def get_in_scope(user_id, artifact_id)
      when is_binary(user_id) and is_binary(artifact_id) do
    user_id
    |> artifact_in_scope_query(artifact_id)
    |> fetch_one()
  end

  @spec get_in_scope_for_update(String.t(), String.t()) ::
          {:ok, Artifact.t()} | {:error, :not_found}
  def get_in_scope_for_update(user_id, artifact_id)
      when is_binary(user_id) and is_binary(artifact_id) do
    user_id
    |> artifact_in_scope_query(artifact_id)
    |> lock("FOR UPDATE")
    |> fetch_one()
  end

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

  @spec list_for_project(String.t(), String.t()) :: [Artifact.t()]
  def list_for_project(user_id, project_id)
      when is_user_project_scope(user_id, project_id) do
    Artifact
    |> where_in_scope(user_id, project_id)
    |> apply_artifact_order()
    |> Repo.all()
  end

  @spec list_for_subject(String.t(), String.t(), String.t(), String.t()) :: [
          Artifact.t()
        ]
  def list_for_subject(user_id, project_id, subject_type, subject_id)
      when is_user_project_scope(user_id, project_id) and is_binary(subject_type) and
             is_binary(subject_id) do
    query = subject_artifacts_query(user_id, project_id, subject_type, subject_id)

    query
    |> select_merge([_artifact, link], %{
      logical_name: link.logical_name,
      metadata: link.metadata
    })
    |> distinct(true)
    |> apply_artifact_order()
    |> Repo.all()
  end

  @spec list_identities_for_subject(String.t(), String.t(), String.t(), String.t()) :: [map()]
  def list_identities_for_subject(user_id, project_id, subject_type, subject_id)
      when is_user_project_scope(user_id, project_id) and is_binary(subject_type) and
             is_binary(subject_id) do
    query = subject_artifacts_query(user_id, project_id, subject_type, subject_id)

    query
    |> where([_artifact, link], not is_nil(link.logical_name))
    |> select([artifact, link], %{
      id: artifact.id,
      logical_name: link.logical_name
    })
    |> apply_artifact_order()
    |> Repo.all()
  end

  @spec get_for_subject_by_logical_name(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: {:ok, Artifact.t()} | {:error, :not_found}
  def get_for_subject_by_logical_name(user_id, project_id, subject_type, subject_id, logical_name)
      when is_user_project_scope(user_id, project_id) and is_binary(subject_type) and
             is_binary(subject_id) and is_binary(logical_name) do
    query = subject_artifacts_query(user_id, project_id, subject_type, subject_id)

    query
    |> where([_artifact, link], link.logical_name == ^logical_name)
    |> select_merge([_artifact, link], %{
      logical_name: link.logical_name,
      metadata: link.metadata
    })
    |> fetch_one()
  end

  defp subject_artifacts_query(user_id, project_id, subject_type, subject_id) do
    Artifact
    |> join(:inner, [artifact], link in ArtifactLink, on: link.artifact_id == artifact.id)
    |> where_in_scope(user_id, project_id)
    |> where_subject_link_in_scope(user_id, project_id, subject_type, subject_id)
  end

  defp where_in_scope(query, user_id, project_id) do
    where(
      query,
      [artifact],
      artifact.user_id == ^user_id and artifact.project_id == ^project_id
    )
  end

  defp artifact_in_scope_query(user_id, artifact_id) do
    where(Artifact, [artifact], artifact.id == ^artifact_id and artifact.user_id == ^user_id)
  end

  defp fetch_one(query) do
    case Repo.one(query) do
      nil -> {:error, :not_found}
      artifact -> {:ok, artifact}
    end
  end

  defp where_subject_link_in_scope(query, user_id, project_id, subject_type, subject_id) do
    where(
      query,
      [_artifact, link],
      link.user_id == ^user_id and link.project_id == ^project_id and
        link.subject_type == ^subject_type and link.subject_id == ^subject_id
    )
  end

  defp apply_artifact_order(query) do
    order_by(query, [artifact], desc: artifact.inserted_at, desc: artifact.id)
  end

  defp project_exists?(user_id, project_id) do
    Project
    |> where([project], project.id == ^project_id and project.user_id == ^user_id)
    |> Repo.exists?()
  end
end
