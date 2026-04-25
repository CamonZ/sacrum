defmodule SacrumWeb.HomeLive do
  use SacrumWeb, :live_view

  alias Sacrum.Repo.WaitlistEntries

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       form: to_form(%{"email" => ""}),
       submitted: false,
       submission_error: nil
     )}
  end

  @impl true
  def handle_event("submit_waitlist", %{"email" => email}, socket) do
    case WaitlistEntries.create(%{email: email}) do
      {:ok, _entry} ->
        {:noreply, success(socket)}

      {:error, changeset} ->
        if duplicate_email?(changeset) do
          {:noreply, success(socket)}
        else
          {:noreply,
           assign(socket,
             form: to_form(changeset),
             submitted: false,
             submission_error: "Please enter a valid email address"
           )}
        end
    end
  end

  defp success(socket) do
    assign(socket,
      form: to_form(%{"email" => ""}),
      submitted: true,
      submission_error: nil
    )
  end

  defp duplicate_email?(changeset) do
    Enum.any?(changeset.errors, fn
      {:email, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end
end
