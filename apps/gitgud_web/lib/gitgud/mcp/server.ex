defmodule GitGud.MCP.Server do
  @moduledoc """
  MCP server exposing the gitfrank/gitgud domain over the Model Context Protocol.

  This server makes gitfrank AI-native: AI agents (AiderDesk, Claude Code, Zed,
  Emacs, …) connect to `POST /api/mcp` (Streamable HTTP), discover the available
  tools with `tools/list`, and invoke them with `tools/call`.

  Tools are plain modules under `GitGud.MCP.Tools.*` that delegate to the
  existing domain queries (`GitGud.RepoQuery`, `GitGud.IssueQuery`, …) and the
  low-level Git bindings via `GitGud.RepoPool`. Authorization is always enforced
  with `GitGud.Authorization`.

  See `guides/MCP.md` for the full design and phased plan.
  """

  @mcp_config Application.compile_env(:gitgud_web, :mcp, [])

  use Anubis.Server,
    name: @mcp_config[:server_name] || "gitfrank",
    version: @mcp_config[:server_version] || "1.0.0",
    capabilities: [:tools]

  # Identity
  component(GitGud.MCP.Tools.WhoAmI)

  # Repositories & code
  component(GitGud.MCP.Tools.SearchRepositories)
  component(GitGud.MCP.Tools.GetRepository)
  component(GitGud.MCP.Tools.ListBranches)
  component(GitGud.MCP.Tools.ListTags)
  component(GitGud.MCP.Tools.GetTree)
  component(GitGud.MCP.Tools.ReadFile)
  component(GitGud.MCP.Tools.GetCommit)

  # Issues
  component(GitGud.MCP.Tools.ListIssues)
  component(GitGud.MCP.Tools.GetIssue)
  component(GitGud.MCP.Tools.ListIssueComments)
  component(GitGud.MCP.Tools.CreateIssue)
  component(GitGud.MCP.Tools.CommentOnIssue)
  component(GitGud.MCP.Tools.UpdateIssueTitle)
  component(GitGud.MCP.Tools.UpdateIssueLabels)
  component(GitGud.MCP.Tools.CloseIssue)
  component(GitGud.MCP.Tools.ReopenIssue)

  # Comments
  component(GitGud.MCP.Tools.UpdateComment)
  component(GitGud.MCP.Tools.DeleteComment)

  # Code review
  component(GitGud.MCP.Tools.CreateCommitLineReviewComment)

  # Releases & search
  component(GitGud.MCP.Tools.ListReleases)
  component(GitGud.MCP.Tools.Search)

  @impl true
  def init(_client_info, frame), do: {:ok, frame}

  @impl true
  def handle_request(request, frame),
    do: GitGud.MCP.ServerHelpers.handle_request_with_filtered_tools(__MODULE__, request, frame)
end
