defmodule GitGud.Web.Markdown do
  @moduledoc """
  Conveniences for rendering Markdown.
  """

  alias GitGud.UserQuery
  alias GitGud.IssueQuery

  alias GitGud.Web.Router.Helpers, as: Routes
  alias GitGud.Web.Emoji

  alias GitRekt.GitAgent

  import Phoenix.HTML, only: [raw: 1]

  @doc """
  Renders a Markdown formatted `content` to HTML.
  """
  @spec markdown(binary | nil, keyword | map) :: binary | nil
  def markdown(content, opts \\ [])
  def markdown(nil, _opts), do: nil
  def markdown(content, opts) when is_map(opts), do: markdown(content, Keyword.new(opts))
  def markdown(content, opts) do
    opts = Keyword.put_new_lazy(opts, :agent, fn -> resolve_agent(Keyword.get(opts, :repo)) end)
    opts = Keyword.put_new_lazy(opts, :users, fn -> find_user_mentions(content) end)
    opts = Keyword.put_new_lazy(opts, :issues, fn -> find_issue_references(content, Keyword.get(opts, :repo)) end)
    case Earmark.as_ast(content) do
      {:ok, ast, _warnings} ->
        ast
        |> transform_ast(opts)
        |> Earmark.Transform.transform()
      {:error, ast, _errors} ->
        ast
        |> transform_ast(opts)
        |> Earmark.Transform.transform()
    end
  end

  @doc """
  Renders a Markdown formatted `content` to HTML and marks it as *safe* for Phoenix to render.
  """
  @spec markdown_safe(binary | nil, keyword | map) :: binary | nil
  def markdown_safe(content, opts \\ [])
  def markdown_safe(nil, _opts), do: nil
  def markdown_safe(content, opts), do: raw(markdown(content, opts))

  #
  # Helpers
  #

  defp transform_ast(ast, opts) do
    ast
    |> Enum.map(&transform_ast_node(&1, opts))
    |> List.flatten()
  end

  defp transform_ast_node({tag, _attrs, _ast, %{}} = node, _opts) when tag in ["code"], do: node
  defp transform_ast_node({tag, attrs, ast, %{}}, opts) do
    {tag, attrs, transform_ast(ast, opts), %{}}
  end

  defp transform_ast_node(content, opts) when is_binary(content) do
    transform_ast_node_text(
      content,
      Regex.scan(~r/\B(@[a-zA-Z0-9_-]+)\b|\B(#[0-9]+)\b|:([a-z0-1_\+]+):|\b([a-f0-9]{7})\b/, content, capture: :first, return: :index),
      Keyword.get(opts, :repo),
      Keyword.get(opts, :agent),
      Keyword.get(opts, :users),
      Keyword.get(opts, :issues)
    )
  end

  defp transform_ast_node_text(content, [], _repo, _agent, _users, _issues), do: content
  defp transform_ast_node_text(content, indexes, repo, agent, users, issues) do
    {content, rest, _offset} =
      Enum.reduce(List.flatten(indexes), {[], content, 0}, fn {idx, len}, {acc, rest, offset} ->
        ofs = idx-offset
        <<head::binary-size(ofs), rest::binary>> = rest
        <<match::binary-size(len), rest::binary>> = rest
        link =
          case match do
            "@" <> login ->
              if user = Enum.find(users, &(&1.login == login)), do:
                {"a", [{"href", Routes.user_path(GitGud.Web.Endpoint, :show, user)}, {"class", "has-text-black"}], ["@#{login}"], %{}}
            "#" <> number_str ->
              number = String.to_integer(number_str)
              if issue = Enum.find(issues, &(&1.number == number)), do:
                {"a", [{"href", Routes.issue_path(GitGud.Web.Endpoint, :show, repo.owner, repo, issue)}], ["##{number}"], %{}}
            match ->
              cond do
                String.starts_with?(match, ":") && String.ends_with?(match, ":") ->
                  Emoji.render(String.slice(match, 1..-2)) || match
                byte_size(match) == 7 && hexadecimal_str?(match) ->
                  if agent do
                    case GitAgent.revision(agent, match) do
                      {:ok, {commit, _ref}} ->
                        {"a", [{"href", Routes.codebase_path(GitGud.Web.Endpoint, :commit, repo.owner, repo, commit)}], [{"code", [{"class", "has-text-link"}], [match], %{}}], %{}}
                      {:error, _reason} ->
                        nil
                    end
                  end
              end
          end || match
        {acc ++ [head, link], rest, idx+len}
      end)
    List.flatten(content, [rest])
  end

  defp resolve_agent(nil), do: nil
  defp resolve_agent(repo) do
    case GitAgent.unwrap(repo) do
      {:ok, agent} ->
        agent
      {:error, _reason} ->
        nil
    end
  end

  defp find_issue_references(_content, nil), do: []
  defp find_issue_references(content, repo) do
    numbers =
      ~r/\B#([0-9]+)\b/
      |> Regex.scan(content, capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(&String.to_integer/1)
      |> Enum.uniq()
    unless Enum.empty?(numbers),
      do: IssueQuery.repo_issues(repo, numbers: numbers),
    else: []
  end

  defp find_user_mentions(content) do
    logins =
      ~r/\B@([a-zA-Z0-9_-]+)\b/
      |> Regex.scan(content, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()
    unless Enum.empty?(logins),
      do: UserQuery.by_login(logins),
    else: []
  end

  defp hexadecimal_str?(str), do: Enum.all?(String.to_charlist(str), &hexadecimal_char?/1)

  defp hexadecimal_char?(c) when c in ?a..?f, do: true
  defp hexadecimal_char?(c) when c in ?0..?9, do: true
  defp hexadecimal_char?(_c), do: false
end
