defmodule GitGud.Web.ReleaseController do

  @moduledoc """
  Module responsible for CRUD actions on `GitGud.Release`.
  """

  use GitGud.Web, :controller

  alias GitGud.RepoQuery
  alias GitGud.Release
  alias GitGud.ReleaseQuery
  alias GitGud.IssueQuery
  alias GitGud.Uploaders.Attachment


  plug :ensure_authenticated when action in [:new, :create]
  plug :put_layout, :repo

  action_fallback GitGud.Web.FallbackController

  @doc """
  Renders all releases of a repository.
  """
  @spec index(Plug.Conn.t, map) :: Plug.Conn.t
  def index(conn, %{"user_login" => user_login, "repo_name" => repo_name} = _params) do
    if repo = RepoQuery.user_repo(user_login, repo_name, viewer: current_user(conn)) do

      query_opts = [order_by: [desc: :inserted_at], preload: [:author]]
      releases = ReleaseQuery.repo_releases(repo, query_opts)
      render(conn, "index.html",
        repo: repo,
        repo_open_issue_count: IssueQuery.count_repo_issues(repo, status: :open),
        releases: releases
      )
    end || {:error, :not_found}
  end

  @doc """
  Renders a release creation form.
  """
  @spec new(Plug.Conn.t, map) :: Plug.Conn.t
  def new(conn, %{"user_login" => user_login, "repo_name" => repo_name} = _params) do
    user = current_user(conn)
    if repo = RepoQuery.user_repo(user_login, repo_name, viewer: user) do
      if verified?(user) do
        render(conn, "new.html",
          repo: repo,
          repo_open_issue_count: IssueQuery.count_repo_issues(repo, status: :open),
          changeset: Release.changeset(%Release{})
        )
      end || {:error, :forbidden}
    end || {:error, :not_found}
  end

  @doc """
  Renders a release edit form.
  """
  @spec edit(Plug.Conn.t, map) :: Plug.Conn.t
  def edit(conn, %{"user_login" => user_login, "repo_name" => repo_name, "id" => id} = _params) do
    user = current_user(conn)
    if repo = RepoQuery.user_repo(user_login, repo_name, viewer: user) do
      if verified?(user) do
        release_id = String.to_integer(id)
        render(conn, "edit.html",
          repo: repo,
          release_id: release_id,
          repo_open_issue_count: IssueQuery.count_repo_issues(repo, status: :open)
        )
      end || {:error, :forbidden}
    end || {:error, :not_found}
  end

  @doc """
  Renders a release.
  """
  @spec show(Plug.Conn.t, map) :: Plug.Conn.t
  def show(conn, %{"user_login" => user_login, "repo_name" => repo_name, "id" => id} = _params) do
    user = current_user(conn)
    if repo = RepoQuery.user_repo(user_login, repo_name, viewer: user) do
      if verified?(user) do
        release_id = String.to_integer(id)
        if release = ReleaseQuery.by_id(release_id, preload: [:author, :attachments]) do
          render(conn, "show.html",
            repo: repo,
            release: release,
            repo_open_issue_count: IssueQuery.count_repo_issues(repo, status: :open)
          )
        end || {:error, :not_found}
      end || {:error, :forbidden}
    end || {:error, :not_found}
  end

  @doc """
  Donwload an attachment of a release.
  """
  @spec download(Plug.Conn.t, map) :: Plug.Conn.t
  def download(conn, %{"user_login" => user_login, "repo_name" => repo_name, "release_id" => release_id, "id" => id} = _params) do
    user = current_user(conn)
    if _repo = RepoQuery.user_repo(user_login, repo_name, viewer: user) do
      if verified?(user) do
        release_id = String.to_integer(release_id)
        if release = ReleaseQuery.by_id(release_id, preload: [:attachments]) do
          if attachment = Enum.find(release.attachments, &(&1.id == String.to_integer(id))) do
            conn
            |> put_resp_header("content-disposition", "attachment; filename=#{attachment.filename}")
            |> send_file(200, Path.join([
                  Attachment.storage_dir_prefix(),
                  Attachment.storage_dir(nil, {nil, release}), attachment.key]))
          end || {:error, :not_found}
        end || {:error, :not_found}
      end || {:error, :forbidden}
    end || {:error, :not_found}
  end

  @doc """
  Creates a new release.
  """
  @spec create(Plug.Conn.t, map) :: Plug.Conn.t
  def create(conn, %{"user_login" => user_login, "repo_name" => repo_name, "release" => release_params} = _params) do
    user = current_user(conn)
    if repo = RepoQuery.user_repo(user_login, repo_name, viewer: user) do
      if verified?(user) do
        case Release.create(repo, user, release_params) do
          {:ok, release} ->
            conn
            |> put_flash(:info, "Release ##{release.tag_version} created.")
            |> redirect(to: Routes.release_path(conn, :index, user_login, repo_name))
          {:error, changeset} ->
            conn
            |> put_flash(:error, "Something went wrong! Please check error(s) below.")
            |> put_status(:bad_request)
            |> render("new.html", repo: repo, repo_open_issue_count: IssueQuery.count_repo_issues(repo, status: :open), changeset: %{changeset|action: :insert})
        end
      end || {:error, :forbidden}
    end || {:error, :not_found}
  end

  @doc """
  Updates a release.
  """
  @spec update(Plug.Conn.t, map) :: Plug.Conn.t
  def update(conn, %{"user_login" => user_login, "repo_name" => repo_name, "id" => id, "release" => release_params} = _params) do
    user = current_user(conn)
    if repo = RepoQuery.user_repo(user_login, repo_name, viewer: user) do
      if verified?(user) do
        release_id = String.to_integer(id)
        if release = ReleaseQuery.by_id(release_id) do
          case Release.update(release, release_params) do
            {:ok, release} ->
              conn
              |> put_flash(:info, "Release ##{release.tag_version} updated.")
              |> redirect(to: Routes.release_path(conn, :show, user_login, repo_name, release_id))
            {:error, changeset} ->
              conn
              |> put_flash(:error, "Something went wrong! Please check error(s) below.")
              |> put_status(:bad_request)
              |> render("edit.html",
                repo: repo,
                release_id: release_id,
                repo_open_issue_count: IssueQuery.count_repo_issues(repo, status: :open),
                changeset: %{changeset|action: :update}
              )
          end
        end || {:error, :not_found}
      end ||  {:error, :forbidden}
    end || {:error, :not_found}
  end

  @doc """
  Deletes a release.
  """
  @spec delete(Plug.Conn.t, map) :: Plug.Conn.t
  def delete(conn, %{"user_login" => user_login, "repo_name" => repo_name, "id" => id} = _params) do
    user = current_user(conn)
    if repo = RepoQuery.user_repo(user_login, repo_name, viewer: user) do
      if verified?(user) do
        release_id = String.to_integer(id)
        if release = ReleaseQuery.by_id(release_id) do
          release = Release.delete!(release)
          conn
          |> put_flash(:info, "Release '#{release.tag_version}' deleted.")
          |> redirect(to: Routes.release_path(conn, :index, repo.owner_login, repo))
        end  || {:error, :not_found}
      end || {:error, :forbidden}
    end || {:error, :not_found}
  end
end
