import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/jido_swarm start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :jido_swarm, JidoSwarmWeb.Endpoint, server: true
end

config :jido_swarm, JidoSwarmWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :jido_swarm, JidoSwarmWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/jido_swarm_web/router\.ex$"E,
        ~r"lib/jido_swarm_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end


# ---------------------------------------------------------------------------
# Swarm runtime configuration
#
# Read for every environment, not just :prod, so the same environment variables
# work when running from a checkout and from the release in Kubernetes.
# ---------------------------------------------------------------------------

# The model. Claude by default; LLM_PROVIDER=ollama switches to the local one.
llm_provider =
  case System.get_env("LLM_PROVIDER", "anthropic") do
    "ollama" -> JidoSwarm.LLM.Ollama
    "local" -> JidoSwarm.LLM.Ollama
    _ -> JidoSwarm.LLM.Anthropic
  end

config :jido_swarm, JidoSwarm.LLM,
  provider: llm_provider,
  ollama: [
    base_url: System.get_env("OLLAMA_BASE_URL", "http://127.0.0.1:11434"),
    model: System.get_env("OLLAMA_MODEL", "qwen3:4b-instruct"),
    num_ctx: String.to_integer(System.get_env("OLLAMA_NUM_CTX", "16384")),
    timeout: String.to_integer(System.get_env("OLLAMA_TIMEOUT_MS", "180000"))
  ],
  anthropic: [
    api_key: System.get_env("ANTHROPIC_API_KEY"),
    model: System.get_env("ANTHROPIC_MODEL", "claude-opus-5"),
    timeout: String.to_integer(System.get_env("ANTHROPIC_TIMEOUT_MS", "600000"))
  ]

config :jido_swarm, JidoSwarm.Swarm.Autoscaler,
  min_workers: String.to_integer(System.get_env("SWARM_MIN_WORKERS", "1")),
  max_workers: String.to_integer(System.get_env("SWARM_MAX_WORKERS", "6")),
  scale_step: String.to_integer(System.get_env("SWARM_SCALE_STEP", "2")),
  interval: String.to_integer(System.get_env("SWARM_INTERVAL_MS", "2000")),
  idle_ttl: String.to_integer(System.get_env("SWARM_IDLE_TTL_MS", "30000"))

# Only the workspace and identity are overridden here. The repository list
# itself stays in config.exs: each entry's `:source` is a local checkout that
# simply does not exist in a container, and `JidoSwarm.Repos` already falls
# back to cloning from `:url` when it is absent.
if workspace = System.get_env("SWARM_WORKSPACE") do
  config :jido_swarm, JidoSwarm.Repos,
    workspace: workspace,
    git_user: System.get_env("GIT_USER", "jido-swarm"),
    git_email: System.get_env("GIT_EMAIL", "jido-swarm@localhost")
end

# Where the knowledge graph lives, and how it is replicated. With
# SWARM_S3_BUCKET set, snapshots and the topic log go to object storage and
# pods that share nothing but the bucket still converge.
context_store =
  if bucket = System.get_env("SWARM_S3_BUCKET") do
    {:s3,
     bucket: bucket,
     prefix: System.get_env("SWARM_S3_PREFIX", "swarm"),
     region: System.get_env("AWS_REGION", "us-east-1"),
     endpoint: System.get_env("SWARM_S3_ENDPOINT"),
     access_key_id: System.get_env("AWS_ACCESS_KEY_ID"),
     secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY")}
  end

context_location =
  case System.get_env("SWARM_GRAPH_PATH") do
    nil -> :memory
    path -> {:disk, path: path}
  end

config :jido_swarm, :context,
  location: context_location,
  store: context_store,
  snapshot_every: String.to_integer(System.get_env("SWARM_SNAPSHOT_EVERY", "25"))

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :jido_swarm, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :jido_swarm, JidoSwarmWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :jido_swarm, JidoSwarmWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :jido_swarm, JidoSwarmWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
