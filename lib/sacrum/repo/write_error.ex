defmodule Sacrum.Repo.WriteError do
  @moduledoc "Classifies persistence rejections for machine-scoped chat writes."

  @spec from_changeset(Ecto.Changeset.t()) :: :not_found | :invalid_payload
  def from_changeset(%Ecto.Changeset{errors: errors}) do
    if Enum.any?(errors, fn {_field, {_message, opts}} ->
         opts[:constraint] in [:foreign, :unique]
       end),
       do: :not_found,
       else: :invalid_payload
  end
end
