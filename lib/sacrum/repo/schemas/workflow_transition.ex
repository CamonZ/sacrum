defmodule Sacrum.Repo.Schemas.WorkflowTransition do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "workflow_transitions" do
    field :label, :string

    belongs_to :from_workflow, Sacrum.Repo.Schemas.Workflow
    belongs_to :to_workflow, Sacrum.Repo.Schemas.Workflow
    belongs_to :target_step, Sacrum.Repo.Schemas.WorkflowStep
    belongs_to :project, Sacrum.Repo.Schemas.Project
    belongs_to :user, Sacrum.Repo.Schemas.User

    timestamps(type: :utc_datetime_usec)
  end

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(transition, attrs) do
    transition
    |> cast(attrs, [:label, :from_workflow_id, :to_workflow_id, :target_step_id])
    |> validate_required([:from_workflow_id, :to_workflow_id])
    |> validate_same_track_transition()
    |> foreign_key_constraint(:from_workflow_id)
    |> foreign_key_constraint(:to_workflow_id)
    |> foreign_key_constraint(:target_step_id)
    |> foreign_key_constraint(:project_id)
    |> unique_constraint([:from_workflow_id, :to_workflow_id],
      message: "transition already exists between these workflows"
    )
  end

  defp validate_same_track_transition(changeset) do
    from_id = Ecto.Changeset.get_field(changeset, :from_workflow_id)
    to_id = Ecto.Changeset.get_field(changeset, :to_workflow_id)

    if is_binary(from_id) and is_binary(to_id) do
      validate_track_match(changeset, from_id, to_id)
    else
      changeset
    end
  end

  defp validate_track_match(changeset, from_id, to_id) do
    import Ecto.Query
    alias Sacrum.Repo.Schemas.Workflow

    workflows =
      Workflow
      |> where([w], w.id in ^[from_id, to_id])
      |> Sacrum.Repo.all()
      |> Map.new(&{&1.id, &1})

    from_wf = Map.get(workflows, from_id)
    to_wf = Map.get(workflows, to_id)

    case {from_wf, to_wf} do
      {%Workflow{track: from_track}, %Workflow{track: to_track}}
      when from_track == to_track ->
        changeset

      {%Workflow{}, %Workflow{}} ->
        Ecto.Changeset.add_error(
          changeset,
          :to_workflow_id,
          "transition must target a workflow in the same track"
        )

      _ ->
        changeset
    end
  end
end
