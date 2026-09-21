# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :jido_swarm,
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :jido_swarm, JidoSwarmWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: JidoSwarmWeb.ErrorHTML, json: JidoSwarmWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: JidoSwarm.PubSub,
  live_view: [signing_salt: "GuMN9eSB"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  jido_swarm: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  jido_swarm: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
# ---------------------------------------------------------------------------
# Swarm
# ---------------------------------------------------------------------------

# Every action in this application is either a model call or a full test run,
# and jido_action's 30s default cuts both off long before they finish.
config :jido_action, default_timeout: 900_000

# The model. Claude by default; ANTHROPIC_API_KEY supplies the key and nothing
# else is needed. Set LLM_PROVIDER=ollama (or :provider here) to go back to the
# local model — the prompts are provider-neutral, so nothing else changes.
config :jido_swarm, JidoSwarm.LLM,
  provider: JidoSwarm.LLM.Anthropic,
  ollama: [
    base_url: "http://127.0.0.1:11434",
    model: "qwen3:4b-instruct",
    num_ctx: 16_384,
    timeout: 180_000
  ],
  anthropic: [
    model: "claude-opus-5",
    timeout: 600_000
  ]

# The elastic pool.
config :jido_swarm, JidoSwarm.Swarm.Autoscaler,
  min_workers: 1,
  max_workers: 6,
  scale_step: 2,
  interval: 2_000,
  idle_ttl: 30_000

# The repositories the swarm works on. `:source` is a local checkout to clone
# from when one exists; in the cluster there is none and `:url` is used.
config :jido_swarm, JidoSwarm.Repos,
  workspace: Path.expand("../tmp/swarm_repos", __DIR__),
  git_user: "jido-swarm",
  git_email: "jido-swarm@localhost",
  repos: [
    %{
      name: "jido",
      url: "https://github.com/djcarpe/jido.git",
      source: "/home/dj/Work/jido",
      default_branch: "main",
      test_command: "mix test",
      description: "An autonomous agent framework for Elixir, built for workflows and multi-agent systems."
    },
    %{
      name: "glider",
      url: "https://github.com/djcarpe/glider.git",
      source: "/home/dj/Work/glider",
      default_branch: "main",
      test_command: "cargo test",
      description: "An embeddable property-graph database in a single binary, with zero external crates."
    },
    %{
      name: "glider_ex",
      url: "https://github.com/djcarpe/glider_ex.git",
      source: "/home/dj/Work/glider_ex",
      default_branch: "main",
      test_command: "mix test",
      description: "Elixir bindings for glider, linked into the BEAM as a Rustler NIF."
    }
  ]

# Where the shared knowledge graph lives, and whether it is replicated beyond
# this node. `:store` nil means in-memory only with :pg replication.
config :jido_swarm, :context,
  location: :memory,
  store: nil,
  snapshot_every: 25

# glider_ex ships a prebuilt NIF in `priv/native`. Where no Rust toolchain is
# present, tell Rustler to load that artifact rather than failing the build.
# The Docker image installs Rust and builds it properly.
if System.find_executable("cargo") == nil do
  config :glider_ex, Glider.Native, skip_compilation?: true
end

import_config "#{config_env()}.exs"
