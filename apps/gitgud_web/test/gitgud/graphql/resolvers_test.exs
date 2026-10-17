defmodule GitGud.GraphQL.ResolversTest do
  use ExUnit.Case, async: true

  alias GitGud.GraphQL.Resolvers
  alias GitGud.Repo
  alias GitGud.User
  alias GitRekt.{GitCommit, GitRef}

  test "resolves an absolute URL for a user" do
    url = GitGud.Web.Endpoint.url() <> "/kanle"
    assert {:ok, ^url} = Resolvers.url(%User{login: "kanle"}, %{}, nil)
  end

  test "resolves an absolute URL for a repo" do
    url = GitGud.Web.Endpoint.url() <> "/kanle/gitfrank"
    repo = %Repo{owner_login: "kanle", name: "gitfrank"}
    assert {:ok, ^url} = Resolvers.url(repo, %{}, nil)
  end

  test "resolves an absolute URL for a git reference" do
    url = GitGud.Web.Endpoint.url() <> "/kanle/gitfrank/tree/main"
    info = %Absinthe.Resolution{context: %{repo: %Repo{owner_login: "kanle", name: "gitfrank"}}}
    assert {:ok, ^url} = Resolvers.url(%GitRef{name: "main"}, %{}, info)
  end

  test "resolves an absolute URL for a git commit" do
    oid = :binary.copy(<<1>>, 20)
    url = GitGud.Web.Endpoint.url() <> "/kanle/gitfrank/commit/#{GitRekt.Git.oid_fmt(oid)}"
    info = %Absinthe.Resolution{context: %{repo: %Repo{owner_login: "kanle", name: "gitfrank"}}}
    assert {:ok, ^url} = Resolvers.url(%GitCommit{oid: oid}, %{}, info)
  end
end
