defmodule Sacrum.Repo.Schemas.Workflow do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "workflows" do
    field :name, :string
    field :description, :string
    field :initial_step_id, :binary_id
    field :metadata, :map, default: %{}
    field :auto_advance, :boolean, default: false
    field :display_order, :integer
    field :is_default, :boolean, default: false
    field :track, :string
    field :kanban_column, :string

    belongs_to :project, Sacrum.Repo.Schemas.Project
    belongs_to :on_done_workflow, Sacrum.Repo.Schemas.Workflow
    belongs_to :on_reject_workflow, Sacrum.Repo.Schemas.Workflow
    belongs_to :user, Sacrum.Repo.Schemas.User
    has_many :workflow_steps, Sacrum.Repo.Schemas.WorkflowStep
    has_many :transitions, Sacrum.Repo.Schemas.WorkflowTransition, foreign_key: :from_workflow_id

    timestamps(type: :utc_datetime_usec)
  end

  @create_fields ~w(name description metadata auto_advance display_order is_default track kanban_column user_id)a
  @update_fields ~w(name description metadata auto_advance display_order is_default initial_step_id on_done_workflow_id on_reject_workflow_id track kanban_column)a

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(workflow, attrs) do
    workflow
    |> cast(attrs, @create_fields)
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_default_workflow_track()
    |> validate_no_inbound_transitions()
    |> foreign_key_constraint(:project_id)
    |> unique_constraint(
      [:project_id, :track],
      name: :workflows_unique_default_per_track,
      message: "default workflow for this track already exists",
      where: "is_default = true"
    )
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(workflow, attrs) do
    workflow
    |> cast(attrs, @update_fields)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_default_workflow_track()
    |> validate_no_inbound_transitions()
    |> foreign_key_constraint(:initial_step_id)
    |> foreign_key_constraint(:on_done_workflow_id)
    |> foreign_key_constraint(:on_reject_workflow_id)
    |> unique_constraint(
      [:project_id, :track],
      name: :workflows_unique_default_per_track,
      message: "default workflow for this track already exists",
      where: "is_default = true"
    )
  end

  defp validate_default_workflow_track(changeset) do
    case Ecto.Changeset.get_field(changeset, :is_default) do
      true ->
        track = Ecto.Changeset.get_field(changeset, :track)

        if is_nil(track) or track == "" do
          Ecto.Changeset.add_error(
            changeset,
            :track,
            "must be set when is_default is true"
          )
        else
          changeset
        end

      _ ->
        changeset
    end
  end

  defp validate_no_inbound_transitions(changeset) do
    is_default = Ecto.Changeset.get_field(changeset, :is_default)
    workflow_id = Ecto.Changeset.get_field(changeset, :id)

    if is_default == true and not is_nil(workflow_id) and
         Ecto.Changeset.get_change(changeset, :is_default) == true do
      check_inbound_transitions(changeset, workflow_id)
    else
      changeset
    end
  end

  defp check_inbound_transitions(changeset, workflow_id) do
    import Ecto.Query
    alias Sacrum.Repo.Schemas.WorkflowTransition

    inbound_count =
      Sacrum.Repo.one(
        from(wt in WorkflowTransition,
          where: wt.to_workflow_id == ^workflow_id,
          select: count(wt.id)
        )
      ) || 0

    if inbound_count > 0 do
      Ecto.Changeset.add_error(
        changeset,
        :is_default,
        "cannot be true when workflow has inbound transitions"
      )
    else
      changeset
    end
  end
end
