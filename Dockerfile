# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Builder
#
# Builds the Elixir release. Rust is needed here because glider_ex is a Rustler
# NIF — glider itself has no crate dependencies, so the compile is quick and
# entirely offline once the toolchain is in place.
# ---------------------------------------------------------------------------
FROM elixir:1.18-slim AS builder

ARG MIX_ENV=prod
ENV MIX_ENV=${MIX_ENV} \
    LANG=C.UTF-8

RUN apt-get update -y \
 && apt-get install -y --no-install-recommends build-essential git ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

# Rust for the NIF. Pinned to a channel rather than a version so the image keeps
# building; glider is plain `std` and not sensitive to the compiler version.
ENV RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo PATH=/usr/local/cargo/bin:$PATH
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --profile minimal --default-toolchain stable

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

# Dependencies first, so a source-only change does not refetch or rebuild them.
# The vendored trees are copied before `deps.get` because two of them are path
# dependencies and must exist for the resolver to succeed.
COPY mix.exs mix.lock ./
COPY vendor ./vendor
RUN mix deps.get --only ${MIX_ENV}

COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY assets assets
COPY lib lib

# Compile before the assets: Phoenix 1.8 extracts colocated hooks and CSS
# during Elixir compilation, and tailwind fails to resolve
# `phoenix-colocated/...` until that has happened.
RUN mix compile
RUN mix assets.deploy

COPY config/runtime.exs config/

RUN mix release

# ---------------------------------------------------------------------------
# Runtime
#
# The swarm runs `mix test` and `cargo test` inside repositories it clones, so
# the runtime image carries the toolchains rather than only the release. That
# makes it large — this is a build agent, not a web server that happens to have
# a UI. Set WITH_RUST=false to drop ~700MB if you do not need the swarm to test
# Rust repositories; glider's suite will then be recorded as unrunnable rather
# than silently skipped.
# ---------------------------------------------------------------------------
FROM elixir:1.18-slim AS runtime

ARG WITH_RUST=true

ENV LANG=C.UTF-8 \
    MIX_ENV=prod \
    PHX_SERVER=true \
    SWARM_WORKSPACE=/var/lib/jido_swarm/repos \
    HOME=/home/swarm

RUN apt-get update -y \
 && apt-get install -y --no-install-recommends \
      git ca-certificates openssl libncurses6 locales curl build-essential \
 && rm -rf /var/lib/apt/lists/*

ENV RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo PATH=/usr/local/cargo/bin:$PATH
RUN if [ "$WITH_RUST" = "true" ]; then \
      curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --profile minimal --default-toolchain stable \
      && chmod -R a+rX /usr/local/rustup /usr/local/cargo; \
    fi

RUN mix local.hex --force && mix local.rebar --force

# Unprivileged, but with a writable HOME: `mix` wants a cache directory, and
# cargo wants somewhere to put its registry when the swarm tests a Rust repo.
RUN useradd --create-home --home-dir /home/swarm --shell /bin/bash swarm \
 && mkdir -p /var/lib/jido_swarm/repos \
 && chown -R swarm:swarm /var/lib/jido_swarm /home/swarm

WORKDIR /app
COPY --from=builder --chown=swarm:swarm /app/_build/prod/rel/jido_swarm ./

USER swarm

# Give the unprivileged user its own hex/rebar install, since the release may
# shell out to mix inside a cloned repository.
RUN mix local.hex --force && mix local.rebar --force

EXPOSE 4000

CMD ["/app/bin/jido_swarm", "start"]
