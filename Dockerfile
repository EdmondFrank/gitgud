ARG ELIXIR_VERSION=1.18.2
ARG ERLANG_VERSION=27.3
ARG ALPINE_VERSION=3.21.3
ARG LINUX_VERSION=alpine-$ALPINE_VERSION

FROM docker.1ms.run/hexpm/elixir:$ELIXIR_VERSION-erlang-$ERLANG_VERSION-$LINUX_VERSION as build

ENV MIX_ENV=prod
ENV ERL_FLAGS="+JPperf true"
ENV HEX_MIRROR="https://hexpm.upyun.com"
ENV HEX_CDN="https://hexpm.upyun.com"
RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.tuna.tsinghua.edu.cn/g' /etc/apk/repositories
WORKDIR /build

# `mix local.hex`/`local.rebar` cap downloads at 60s (Mix.Utils.fetch_url) and fail
# on slow links; HEX_MIRROR only mirrors packages, not /installs. Fetch the
# archives with curl (retry, no cap) and install them from disk instead. The
# versions are those Mix resolves for Elixir 1.18.2 (hex-1.x.csv/rebar3-1.x.csv).
ARG HEX_BUILDS_URL="https://builds.hex.pm"
RUN apk add --no-cache build-base erlang-dev libgit2-dev git nodejs npm curl && \
    curl -fsSL --retry 8 --retry-delay 5 -o /tmp/hex.ez "${HEX_BUILDS_URL}/installs/1.16.0/hex-2.5.3.ez" && \
    curl -fsSL --retry 8 --retry-delay 5 -o /tmp/rebar3 "${HEX_BUILDS_URL}/installs/1.15.0-rc.0/rebar3-3.22.0" && \
    mix archive.install /tmp/hex.ez --force && \
    mix local.rebar rebar3 /tmp/rebar3 --force

COPY mix.exs mix.lock ./
COPY apps/gitrekt/mix.exs apps/gitrekt/
COPY apps/gitgud/mix.exs apps/gitgud/
COPY apps/gitgud_web/mix.exs apps/gitgud_web/

RUN mix do deps.get --only prod, deps.compile --skip-umbrella-children

COPY apps/gitrekt/Makefile apps/gitrekt/
COPY apps/gitrekt/c_src apps/gitrekt/c_src
COPY apps/gitrekt/config apps/gitrekt/config
COPY apps/gitrekt/lib apps/gitrekt/lib

COPY apps/gitgud/config  apps/gitgud/config
COPY apps/gitgud/lib apps/gitgud/lib
COPY apps/gitgud/priv apps/gitgud/priv

COPY apps/gitgud_web/config apps/gitgud_web/config
COPY apps/gitgud_web/lib apps/gitgud_web/lib
COPY apps/gitgud_web/priv/ apps/gitgud_web/priv

COPY config ./config

RUN mix compile

COPY apps/gitgud_web/assets/ apps/gitgud_web/assets

RUN npm ci --prefix apps/gitgud_web/assets --no-audit --no-fund

RUN cd apps/gitgud_web && mix assets.deploy

# RUN mix phx.digest /build/apps/gitgud_web/priv/static

# COPY rel ./rel

RUN mix release

FROM docker.1ms.run/hexpm/elixir:$ELIXIR_VERSION-erlang-$ERLANG_VERSION-$LINUX_VERSION as app

RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.tuna.tsinghua.edu.cn/g' /etc/apk/repositories
RUN apk add --no-cache libgit2 openssl openssh-keygen ncurses-libs imagemagick

WORKDIR /app

RUN chown nobody:nobody /app

COPY --from=build --chown=nobody:nobody /build/_build/prod/rel/gitgud ./
COPY entrypoint.sh ./

# RUN mkdir ssh-keys
# RUN yes y | ssh-keygen -m PEM -t rsa -N "" -f ssh-keys/ssh_host_rsa_key

EXPOSE 4000
EXPOSE 1022

ARG APP_REVISION
ENV APP_REVISION=$APP_REVISION

ENTRYPOINT ["./entrypoint.sh"]
CMD ["bin/gitgud", "start"]
