defmodule GitGud.Web.ReleaseFormLive do
  use GitGud.Web, :live_view
  @moduledoc """
  Live view responsible for rendering a release form.
  """

  alias GitGud.Repo
  alias GitGud.Release
  alias GitGud.RepoQuery
  alias GitGud.ReleaseQuery

  import Ecto.Changeset

  #
  # Callbacks
  #

  @impl true
  def mount(_, %{"repo_id" => repo_id, "release_id" => release_id} = session, socket) do
    with repo <- RepoQuery.by_id(repo_id),
         release <- ReleaseQuery.by_id(release_id),
         tags <- Repo.tags(repo) do
      {
        :ok,
        socket
        |> authenticate(session)
        |> assign_new(:repo, fn -> repo end)
        |> assign_new(:tags,  fn -> tags end)
        |> assign_new(:release, fn -> release end)
        |> assign_changeset(release)
        |> assign(trigger_submit: false, new_record: false)
      }
    end
  end

  def mount(_, %{"repo_id" => repo_id} = session, socket) do
    with repo <- RepoQuery.by_id(repo_id),
         tags <- Repo.tags(repo) do
      {
        :ok,
        socket
        |> authenticate(session)
        |> assign_new(:repo, fn -> repo end)
        |> assign_new(:tags,  fn -> tags end)
        |> assign_changeset()
        |> assign(trigger_submit: false, new_record: true)
      }
    end
  end

  @impl true
  def handle_event("validate", %{"release" => release_params}, socket) do
    changeset =
      %Release{}
      |> Release.changeset(release_params)
      |> validate_tag(socket.assigns.tags)
    {:noreply, assign(socket, changeset: changeset)}
  end

  def handle_event("submit", %{"release" => release_params}, socket) do
    changeset = Release.changeset(%Release{}, release_params)
    case Ecto.Changeset.apply_action(changeset, if(socket.assigns.new_record, do: :insert, else: :update)) do
      {:ok, _release} ->
        {:noreply, assign(socket, changeset: changeset, trigger_submit: true)}
      {:error, changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end

  #
  # Helpers
  #

  defp validate_tag(changeset, available_tags) do
    revision = get_change(changeset, :revision)
    cond do
      is_nil(revision) ->
        changeset
        Enum.find(available_tags, fn tag ->
          elem(tag, 0).oid
          |> Base.encode16(case: :lower)
          |> Kernel.==(revision)
        end) ->
        changeset
      true ->
        add_error(changeset, :revision, "no such tag")
    end
  end

  defp assign_changeset(socket, release \\ %Release{}) do
    assign_new(socket, :changeset, fn -> Release.changeset(release) end)
  end
end
