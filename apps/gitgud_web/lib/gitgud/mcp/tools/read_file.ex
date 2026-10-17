defmodule GitGud.MCP.Tools.ReadFile do
  @moduledoc """
  MCP tool `read_file` — read a blob's content at a revision/path.

  The content is returned as UTF-8 text when valid, otherwise base64. Output is
  truncated to `max_bytes` (default 256 KiB, max 1 MiB) with a `truncated` flag.
  """

  use Anubis.Server.Component, type: :tool

  alias GitGud.MCP.Authorization
  alias GitGud.MCP.Tools.Helpers

  alias GitRekt.GitAgent
  alias GitRekt.GitRepo

  def name, do: "read_file"

  @impl true
  def description do
    "Read a blob's content at a given revision and path (UTF-8 text or base64, truncated to max_bytes)."
  end

  schema do
    field(:owner, {:required, :string}, description: "Repository owner login.")
    field(:name, {:required, :string}, description: "Repository name.")
    field(:path, {:required, :string}, description: "Blob path relative to the repository root.")

    field(:revision, :string,
      description: "Branch, tag or commit oid (default: the repository default branch)."
    )

    field(:max_bytes, :integer,
      description: "Maximum number of bytes to return (1-1048576).",
      default: 262_144
    )
  end

  @impl true
  def execute(params, frame) do
    user = Helpers.current_user(frame)
    path = params[:path]
    max_bytes = Helpers.clamp_max_bytes(params[:max_bytes])

    result =
      with {:ok, repo} <- Authorization.fetch_repo(user, params[:owner], params[:name]),
           {:ok, agent} <- GitRepo.get_agent(repo) do
        revision = params[:revision] || repo.default_branch

        GitAgent.transaction(agent, fn agent ->
          with {:ok, {object, _ref}} <- GitAgent.revision(agent, revision),
               {:ok, commit} <- GitAgent.peel(agent, object, target: :commit),
               {:ok, tree_entry} <- GitAgent.tree_entry_by_path(agent, commit, path),
               {:ok, blob} <- GitAgent.peel(agent, tree_entry),
               {:ok, content} <- GitAgent.blob_content(agent, blob),
               {:ok, size} <- GitAgent.blob_size(agent, blob) do
            {:ok, payload(Helpers.oid(commit.oid), path, content, size, max_bytes)}
          end
        end)
      end

    Helpers.reply(frame, result)
  end

  #
  # Helpers
  #

  defp payload(oid, path, content, size, max_bytes) do
    truncated? = byte_size(content) > max_bytes
    data = if truncated?, do: binary_part(content, 0, max_bytes), else: content

    base = %{"commit" => oid, "path" => path, "size" => size, "truncated" => truncated?}

    if String.valid?(data) do
      Map.merge(base, %{"encoding" => "utf-8", "content" => data})
    else
      Map.merge(base, %{"encoding" => "base64", "content" => Base.encode64(data)})
    end
  end
end
