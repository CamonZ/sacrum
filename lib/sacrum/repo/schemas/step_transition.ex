defmodule Sacrum.Repo.Schemas.StepTransition do
  @moduledoc """
  A directed edge between two steps of one workflow.

  `session` is the optional session directive (`Sacrum.Routing.SessionDirective`)
  the edge carries into an `llm_inference` destination; nil enters a new
  conversation. The changeset fixes its shape; which steps it may name is
  proved against the workflow graph by `Sacrum.Routing.RouteValidator`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Sacrum.Routing.SessionDirective

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "step_transitions" do
    field :label, :string
    field :session, :map

    belongs_to :from_step, Sacrum.Repo.Schemas.WorkflowStep
    belongs_to :to_step, Sacrum.Repo.Schemas.WorkflowStep
    belongs_to :project, Sacrum.Repo.Schemas.Project
    belongs_to :user, Sacrum.Repo.Schemas.User

    timestamps(type: :utc_datetime_usec)
  end

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(transition, attrs) do
    transition
    |> cast(attrs, [:label, :from_step_id, :to_step_id])
    |> put_session(attrs)
    |> validate_required([:from_step_id, :to_step_id])
    |> foreign_key_constraint(:from_step_id)
    |> foreign_key_constraint(:to_step_id)
    |> foreign_key_constraint(:project_id)
    |> unique_constraint([:from_step_id, :to_step_id],
      message: "transition already exists between these steps"
    )
  end

  @doc "Changes the label and session directive of an existing transition."
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(transition, attrs) do
    transition
    |> cast(attrs, [:label])
    |> put_session(attrs)
  end

  defp put_session(changeset, attrs) do
    case fetch_session(attrs) do
      :error -> changeset
      {:ok, nil} -> put_change(changeset, :session, nil)
      {:ok, session} -> decode_session(changeset, session)
    end
  end

  defp fetch_session(attrs) do
    with :error <- Map.fetch(attrs, :session), do: Map.fetch(attrs, "session")
  end

  defp decode_session(changeset, session) do
    case SessionDirective.decode(session, "$.session") do
      {:ok, directive} ->
        put_change(changeset, :session, SessionDirective.encode(directive))

      {:error, %{path: path, message: message}} ->
        add_error(changeset, :session, "#{describe(changeset)} #{path}: #{message}")
    end
  end

  @doc "Names a transition by its endpoints in session diagnostics."
  @spec describe(Ecto.Changeset.t() | t() | map()) :: String.t()
  def describe(%Ecto.Changeset{} = changeset),
    do:
      describe(%{
        from_step_id: get_field(changeset, :from_step_id),
        to_step_id: get_field(changeset, :to_step_id)
      })

  def describe(%{from_step_id: from, to_step_id: to}), do: "step transition #{from} -> #{to}"
end
