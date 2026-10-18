defmodule GitGud.GraphQL.CheckpointTest do
  @moduledoc """
  Query-level coverage for the AI coding-agent checkpoint API: the repository
  `checkpoints`/`checkpoint` fields, the commit `checkpoints` field (Phase 3) and
  the repository `searchCheckpoints`/`checkpointProvenance` fields (Phase 4; see
  `guides/Sessions and Checkpoints.md`).

  Unlike `GitGud.GraphQL.ResolversTest` these run a real document through
  `GitGud.GraphQL.Schema`, so they also exercise `GitGud.GraphQL.RepoMiddleware`.
  """

  use GitGud.Web.ConnCase, async: false
  use GitGud.Web.DataFactory

  alias GitGud.Checkpoints
  alias GitGud.GraphQL.Schema
  alias GitGud.Repo
  alias GitGud.RepoStorage
  alias GitGud.User
  alias GitGud.Web.CheckpointFactory

  setup do
    user = User.create!(factory(:user))
    repo = create_repo(user)
    %{main_sha: main_sha} = CheckpointFactory.write!(repo)

    %{user: user, repo: repo, main_sha: main_sha}
  end

  test "resolves the repository checkpoints", %{user: user, repo: repo, main_sha: main_sha} do
    result =
      run!(
        """
        query($owner: String!, $name: String!) {
          repo(owner: $owner, name: $name) {
            checkpoints(first: 10) {
              edges { node { id, oid, ref, source, branch, strategy, sessionCount, filesTouched, commitSha, tokenUsage, url } }
            }
          }
        }
        """,
        %{"owner" => user.login, "name" => repo.name},
        user
      )

    assert %{"repo" => %{"checkpoints" => %{"edges" => [%{"node" => checkpoint}]}}} =
             result[:data]

    assert checkpoint["id"] == CheckpointFactory.checkpoint_id()
    assert checkpoint["ref"] == CheckpointFactory.checkpoint_ref()
    assert checkpoint["source"] == "REF"
    assert checkpoint["branch"] == "main"
    assert checkpoint["strategy"] == "manual-commit"
    assert checkpoint["sessionCount"] == 1
    assert checkpoint["filesTouched"] == ["README.md", "SECOND.md"]
    assert checkpoint["commitSha"] == main_sha
    assert checkpoint["oid"] =~ ~r/\A[0-9a-f]{40}\z/
    assert checkpoint["tokenUsage"] == %{"input_tokens" => 158, "output_tokens" => 54}

    assert checkpoint["url"] ==
             GitGud.Web.Endpoint.url() <>
               "/#{user.login}/#{repo.name}/sessions/#{CheckpointFactory.checkpoint_id()}"
  end

  test "resolves a single checkpoint with its raw metadata", %{user: user, repo: repo} do
    result =
      run!(
        """
        query($owner: String!, $name: String!, $id: String!) {
          repo(owner: $owner, name: $name) {
            checkpoint(id: $id) { id, strategy, sessionCount, metadata }
          }
        }
        """,
        %{
          "owner" => user.login,
          "name" => repo.name,
          "id" => CheckpointFactory.checkpoint_id()
        },
        user
      )

    assert %{"repo" => %{"checkpoint" => checkpoint}} = result[:data]
    assert checkpoint["id"] == CheckpointFactory.checkpoint_id()
    assert checkpoint["strategy"] == "manual-commit"
    assert checkpoint["sessionCount"] == 1
    assert checkpoint["metadata"]["strategy"] == "manual-commit"
    assert [%{"metadata" => "/0/metadata.json"}] = checkpoint["metadata"]["sessions"]
  end

  test "resolves the checkpoints linked to a commit", %{
    user: user,
    repo: repo,
    main_sha: main_sha
  } do
    result =
      run!(
        """
        query($owner: String!, $name: String!, $spec: String!) {
          repo(owner: $owner, name: $name) {
            revision(spec: $spec) {
              oid
              checkpoints(first: 10) { edges { node { id, commitSha } } }
            }
          }
        }
        """,
        %{"owner" => user.login, "name" => repo.name, "spec" => main_sha},
        user
      )

    assert %{
             "repo" => %{
               "revision" => %{
                 "oid" => oid,
                 "checkpoints" => %{"edges" => [%{"node" => checkpoint}]}
               }
             }
           } = result[:data]

    assert oid == main_sha
    assert checkpoint["id"] == CheckpointFactory.checkpoint_id()
    assert checkpoint["commitSha"] == main_sha
  end

  test "reports an unknown checkpoint id as an error", %{user: user, repo: repo} do
    result =
      run!(
        """
        query($owner: String!, $name: String!) {
          repo(owner: $owner, name: $name) { checkpoint(id: "nope") { id } }
        }
        """,
        %{"owner" => user.login, "name" => repo.name},
        user
      )

    assert %{"repo" => %{"checkpoint" => nil}} = result[:data]
    assert [%{message: message} | _] = result[:errors]
    assert message =~ "is not valid"
  end

  test "searches the repository checkpoints", %{user: user, repo: repo} do
    result =
      run!(
        """
        query($owner: String!, $name: String!) {
          repo(owner: $owner, name: $name) {
            searchCheckpoints(query: "greeting", first: 10) {
              edges { node { matched, score, checkpoint { id, branch } } }
            }
          }
        }
        """,
        %{"owner" => user.login, "name" => repo.name},
        user
      )

    assert %{
             "repo" => %{
               "searchCheckpoints" => %{
                 "edges" => [%{"node" => %{"checkpoint" => checkpoint} = node}]
               }
             }
           } = result[:data]

    assert node["matched"] == ["session 0 prompt"]
    assert node["score"] == 3
    assert checkpoint["id"] == CheckpointFactory.checkpoint_id()
    assert checkpoint["branch"] == "main"
  end

  test "reports no search match", %{user: user, repo: repo} do
    result =
      run!(
        """
        query($owner: String!, $name: String!) {
          repo(owner: $owner, name: $name) {
            searchCheckpoints(query: "nonexistent", first: 10) { edges { node { matched } } }
          }
        }
        """,
        %{"owner" => user.login, "name" => repo.name},
        user
      )

    assert %{"repo" => %{"searchCheckpoints" => %{"edges" => []}}} = result[:data]
  end

  test "resolves the checkpoints that touched a path", %{user: user, repo: repo} do
    result =
      run!(
        """
        query($owner: String!, $name: String!) {
          repo(owner: $owner, name: $name) {
            checkpointProvenance(path: "README.md", first: 10) {
              edges { node { matched, score, checkpoint { id, commitSha } } }
            }
          }
        }
        """,
        %{"owner" => user.login, "name" => repo.name},
        user
      )

    assert %{"repo" => %{"checkpointProvenance" => %{"edges" => [%{"node" => node}]}}} =
             result[:data]

    assert node["matched"] == ["README.md"]
    assert node["score"] == 1
    assert node["checkpoint"]["id"] == CheckpointFactory.checkpoint_id()
  end

  test "reports an unknown path as empty", %{user: user, repo: repo} do
    result =
      run!(
        """
        query($owner: String!, $name: String!) {
          repo(owner: $owner, name: $name) {
            checkpointProvenance(path: "nope.md", first: 10) { edges { node { matched } } }
          }
        }
        """,
        %{"owner" => user.login, "name" => repo.name},
        user
      )

    assert %{"repo" => %{"checkpointProvenance" => %{"edges" => []}}} = result[:data]
  end

  #
  # Helpers
  #

  defp run!(document, variables, user) do
    opts = [context: %{current_user: user}, variables: variables]

    assert {:ok, result} = Schema.run(document, opts)

    result
  end

  defp create_repo(user) do
    repo = Repo.create!(user, factory(:repo))

    on_exit(fn ->
      File.rm_rf(RepoStorage.workdir(repo))
      Checkpoints.invalidate(repo)
    end)

    repo
  end
end
