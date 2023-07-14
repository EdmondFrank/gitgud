import Config

# Configure your database
config :gitgud, GitGud.DB,
  username: "postgres",
  password: "postgres",
  database: "gitgud_prod",
  hostname: "localhost",
  pool_size: 10

config :gitgud, GitGud.MetaDB,
  data_dir: System.get_env("METADATA_DIR")

config :gitgud, GitGud.ContentStore,
  data_dir: System.get_env("LFS_DIR")

# Configure your SSH server
config :gitgud, GitGud.SSHServer,
  port: System.get_env("SSH_PORT"),
  host_key_dir: System.get_env("SSH_HOST_KEY_DIR")

# Configure your Git storage location
config :gitgud, GitGud.RepoStorage,
  git_root: System.get_env("GIT_ROOT")

# Configure your repository pool
config :gitgud, GitGud.RepoPool,
  max_children_per_pool: 10
