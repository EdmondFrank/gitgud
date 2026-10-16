import Config

# Configure your database
# Local credentials match the Docker database started via
# `docker compose -f docker-compose-dev.yml up -d`.
# CI (GitHub Actions) overrides these below.
config :gitgud, GitGud.DB,
  username: "gitfrank_user",
  password: "gitfrank_pass",
  database: "gitgud_test",
  hostname: "localhost",
  pool: Ecto.Adapters.SQL.Sandbox

# Configure your database for GitHub Actions
if System.get_env("GITHUB_ACTIONS") do
  config :gitgud, GitGud.DB,
    username: "postgres",
    password: "postgres"
end

# Configure metadata and content storage
config :gitgud, GitGud.MetaDB,
  data_dir: Path.absname("test/data/meta-data", Path.dirname(__DIR__))

config :gitgud, GitGud.ContentStore,
  data_dir: Path.absname("test/data/lfs-data", Path.dirname(__DIR__))

# Configure your SSH server
config :gitgud, GitGud.SSHServer,
  port: 9899,
  host_key_dir: Path.absname("priv/ssh-keys", Path.dirname(__DIR__))

# Configure your Git storage location
config :gitgud, GitGud.RepoStorage,
  git_root: Path.absname("test/data/git", Path.dirname(__DIR__))

# Configure your repository pool
config :gitgud, GitGud.RepoPool,
  max_children_per_pool: 3
