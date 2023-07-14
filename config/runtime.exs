import Config

if config_env() == :prod do

  app_name = "gitfrank"

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
    raise """
    environment variable SECRET_KEY_BASE is missing.
    You can generate one by calling: mix phx.gen.secret
    """

  database_url =
    System.get_env("DATABASE_URL") ||
    raise """
    environment variable DATABASE_URL is missing.
    For example: ecto://USER:PASS@HOST/DATABASE
    """

  git_root =
    System.get_env("GIT_ROOT") ||
    raise "environment variable GIT_ROOT is missing."

  ssh_host_key_dir =
    System.get_env("SSH_HOST_KEY_DIR") ||
    raise "environment variable SSH_HOST_KEY_DIR is missing."

  uploads_dir =
    System.get_env("UPLOADS_DIR") ||
    raise "environment variable UPLOADS_DIR is missing."

  asset_host =
    System.get_env("ASSET_HOST") ||
    raise "environment variable ASSET_HOST is missing."

  meta_dir =
      System.get_env("METADATA_DIR") ||
    raise "environment variable METADATA_DIR is missing."

  lfs_dir =
      System.get_env("LFS_DIR") ||
    raise "environment variable LFS_DIR is missing."

  config :gitgud, GitGud.DB,
    url: database_url,
    ssl: false,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  config :gitgud, GitGud.MetaDB,
    data_dir: meta_dir

  config :gitgud, GitGud.ContentStore,
    data_dir: lfs_dir

  config :gitgud, GitGud.RepoStorage, git_root: git_root

  config :waffle,
    storage_dir_prefix: uploads_dir,
    asset_host: asset_host

  config :gitgud, GitGud.SSHServer,
    port: String.to_integer(System.get_env("SSH_PORT") || "1022"),
    host_key_dir: ssh_host_key_dir

  config :gitgud_web, GitGud.Web.Endpoint,
    server: true,
    url: [scheme: "http", host: "175.178.76.69", port: 4000],
    http: [
      port: String.to_integer(System.get_env("PORT") || "4000"),
      transport_options: [socket_opts: [:inet6]]
    ],
    check_origin: false,
    secret_key_base: secret_key_base

  config :gitgud_web, GitGud.Mailer,
    adapter: Bamboo.MailgunAdapter,
    api_key: System.get_env("MAILGUN_API_KEY"),
    domain: "mail.git.limo"

  config :gitgud_web, GitGud.OAuth2.GitHub,
    client_id: System.get_env("OAUTH2_GITHUB_CLIENT_ID"),
    client_secret: System.get_env("OAUTH2_GITHUB_CLIENT_SECRET")

  config :gitgud_web, GitGud.OAuth2.GitLab,
    client_id: System.get_env("OAUTH2_GITLAB_CLIENT_ID"),
    client_secret: System.get_env("OAUTH2_GITLAB_CLIENT_SECRET")

  config :gitgud_web, GitGud.OAuth2.Gitee,
    client_id: System.get_env("OAUTH2_GITEE_CLIENT_ID"),
    client_secret: System.get_env("OAUTH2_GITEE_CLIENT_SECRET")
end
