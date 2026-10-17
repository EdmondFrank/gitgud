defmodule GitGud.PersonalAccessTokenTest do
  use GitGud.DataCase, async: true
  use GitGud.DataFactory

  alias GitGud.PersonalAccessToken
  alias GitGud.PersonalAccessTokenQuery
  alias GitGud.User

  setup :create_user

  describe "create/2" do
    test "returns the plaintext once and stores only the prefix and hash", %{user: user} do
      assert {:ok, {token, plaintext}} =
               PersonalAccessToken.create(user, %{
                 name: "AiderDesk",
                 scopes: ["repo:read", "issue:write"]
               })

      assert String.starts_with?(plaintext, PersonalAccessToken.token_prefix())
      assert byte_size(plaintext) > 40
      assert token.token_prefix == String.slice(plaintext, 0, 12)
      assert token.token_hash == :crypto.hash(:sha256, plaintext)
      refute token.token_hash == plaintext
      assert token.scopes == ["repo:read", "issue:write"]
      assert token.user_id == user.id
      assert PersonalAccessToken.active?(token)
    end

    test "requires a name", %{user: user} do
      assert {:error, changeset} = PersonalAccessToken.create(user, %{scopes: ["repo:read"]})
      assert %{name: _} = errors_on(changeset)
    end

    test "requires at least one valid scope", %{user: user} do
      assert {:error, changeset} =
               PersonalAccessToken.create(user, %{name: "no scopes", scopes: []})

      assert Map.has_key?(errors_on(changeset), :scopes)

      assert {:error, changeset} =
               PersonalAccessToken.create(user, %{name: "bad scope", scopes: ["not:a:scope"]})

      assert Map.has_key?(errors_on(changeset), :scopes)
    end
  end

  describe "prefix/1 and matches?/2" do
    test "prefix/1 is nil for tokens without the token prefix", %{user: user} do
      assert PersonalAccessToken.prefix("not-a-token") == nil
      assert PersonalAccessToken.prefix(nil) == nil

      assert {:ok, {_token, plaintext}} =
               PersonalAccessToken.create(user, %{name: "t", scopes: ["user:read"]})

      assert PersonalAccessToken.prefix(plaintext) == String.slice(plaintext, 0, 12)
    end

    test "matches?/2 compares in constant time", %{user: user} do
      assert {:ok, {token, plaintext}} =
               PersonalAccessToken.create(user, %{name: "t", scopes: ["user:read"]})

      assert PersonalAccessToken.matches?(token, plaintext)
      refute PersonalAccessToken.matches?(token, plaintext <> "x")
      refute PersonalAccessToken.matches?(token, nil)
    end
  end

  describe "active?/1" do
    test "a revoked token is inactive", %{user: user} do
      {:ok, {token, _plaintext}} =
        PersonalAccessToken.create(user, %{name: "t", scopes: ["user:read"]})

      assert {:ok, revoked} = PersonalAccessToken.revoke(token)
      assert revoked.revoked_at
      refute PersonalAccessToken.active?(revoked)
    end

    test "an expired token is inactive", %{user: user} do
      expires_at =
        DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      {:ok, {token, _plaintext}} =
        PersonalAccessToken.create(user, %{
          name: "t",
          scopes: ["user:read"],
          expires_at: expires_at
        })

      refute PersonalAccessToken.active?(token)
    end
  end

  describe "PersonalAccessTokenQuery" do
    test "authenticate/1 resolves a valid token", %{user: user} do
      {:ok, {token, plaintext}} =
        PersonalAccessToken.create(user, %{name: "t", scopes: ["repo:read"]})

      assert {:ok, found} = PersonalAccessTokenQuery.authenticate(plaintext)
      assert found.id == token.id
    end

    test "authenticate/1 rejects unknown, malformed and revoked tokens", %{user: user} do
      assert {:error, :invalid_token} = PersonalAccessTokenQuery.authenticate("nope")

      assert {:error, :invalid_token} =
               PersonalAccessTokenQuery.authenticate("gf_" <> String.duplicate("a", 52))

      {:ok, {token, plaintext}} =
        PersonalAccessToken.create(user, %{name: "t", scopes: ["repo:read"]})

      assert {:ok, _token} = PersonalAccessToken.revoke(token)
      assert {:error, :invalid_token} = PersonalAccessTokenQuery.authenticate(plaintext)
    end

    test "touch/1 records last_used_at", %{user: user} do
      {:ok, {token, _plaintext}} =
        PersonalAccessToken.create(user, %{name: "t", scopes: ["repo:read"]})

      refute token.last_used_at

      assert {:ok, touched} = PersonalAccessTokenQuery.touch(token)
      assert touched.last_used_at
    end

    test "user_tokens/1 only returns the user's tokens", %{user: user} do
      other = User.create!(factory(:user))

      {:ok, {token1, _plaintext}} =
        PersonalAccessToken.create(user, %{name: "one", scopes: ["repo:read"]})

      {:ok, {token2, _plaintext}} =
        PersonalAccessToken.create(user, %{name: "two", scopes: ["user:read"]})

      {:ok, {_token3, _plaintext}} =
        PersonalAccessToken.create(other, %{name: "three", scopes: ["repo:read"]})

      ids = PersonalAccessTokenQuery.user_tokens(user) |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([token1.id, token2.id])
    end

    test "by_id/1 and by_prefix/1 find the token", %{user: user} do
      {:ok, {token, plaintext}} =
        PersonalAccessToken.create(user, %{name: "t", scopes: ["repo:read"]})

      assert PersonalAccessTokenQuery.by_id(token.id).id == token.id

      assert PersonalAccessTokenQuery.by_prefix(PersonalAccessToken.prefix(plaintext)).id ==
               token.id

      assert PersonalAccessTokenQuery.by_prefix("gf_000000000") == nil
    end
  end

  #
  # Helpers
  #

  defp create_user(context) do
    Map.put(context, :user, User.create!(factory(:user)))
  end
end
