ARG ELIXIR_VERSION=1.18.2
ARG ERLANG_VERSION=27.3
ARG ALPINE_VERSION=3.21.3
ARG LINUX_VERSION=alpine-$ALPINE_VERSION

FROM docker.1ms.run/hexpm/elixir:$ELIXIR_VERSION-erlang-$ERLANG_VERSION-$LINUX_VERSION as build

# --- Zig: the C toolchain that builds the `gitrekt` NIF ----------------------
# `apps/gitrekt/build.zig` compiles `c_src/*.c` into `priv/geef_nif.so` with Zig's
# bundled clang, which sidesteps the GCC 14 / clang 20+ `-Wincompatible-pointer-types`
# breakage. The official tarball is used instead of `apk add zig` because Alpine
# only ships zig <= 0.16 (3.21 has 0.13.0) and `build.zig` requires 0.17; the Linux
# tarballs are statically linked, so they run unchanged on musl. Point `ZIG_MIRROR`
# at a domestic mirror when the build host is in China.
ARG ZIG_VERSION=0.17.0
ARG ZIG_MIRROR=https://ziglang.org/download
ARG ZIG_SHA256_X86_64=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026
ARG ZIG_SHA256_AARCH64=9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8

# --- mirrors (build speed) ---------------------------------------------------
# apk (tuna), hex (upyun, above) and npm (npmmirror) all default to domestic
# endpoints; override any of them with `--build-arg` for a non-CN build.
ARG APK_MIRROR_HOST=mirrors.tuna.tsinghua.edu.cn
ARG NPM_REGISTRY=https://registry.npmmirror.com

ENV MIX_ENV=prod
ENV ERL_FLAGS="+JPperf true"
ENV HEX_MIRROR="https://hexpm.upyun.com"
ENV HEX_CDN="https://hexpm.upyun.com"
RUN sed -i "s/dl-cdn.alpinelinux.org/${APK_MIRROR_HOST}/g" /etc/apk/repositories
WORKDIR /build

# `mix local.hex`/`local.rebar` cap downloads at 60s (Mix.Utils.fetch_url) and fail
# on slow links; HEX_MIRROR only mirrors packages, not /installs. Fetch the
# archives with curl (retry, no cap) and install them from disk instead. The
# versions are those Mix resolves for Elixir 1.18.2 (hex-1.x.csv/rebar3-1.x.csv).
ARG HEX_BUILDS_URL="https://builds.hex.pm"
# `pkgconf` lets `zig build` resolve libgit2's `libgit2.pc`; `xz` unpacks the Zig
# tarball. `build-base` is still required: the other C extensions (`argon2_elixir`,
# `cmark`) keep compiling with the system compiler.
RUN apk add --no-cache build-base erlang-dev libgit2-dev git nodejs npm curl pkgconf xz && \
    curl -fsSL --retry 8 --retry-delay 5 -o /tmp/hex.ez "${HEX_BUILDS_URL}/installs/1.16.0/hex-2.5.3.ez" && \
    curl -fsSL --retry 8 --retry-delay 5 -o /tmp/rebar3 "${HEX_BUILDS_URL}/installs/1.15.0-rc.0/rebar3-3.22.0" && \
    mix archive.install /tmp/hex.ez --force && \
    mix local.rebar rebar3 /tmp/rebar3 --force

# sha256-pinned Zig install; `zig version` doubles as a smoke test.
RUN set -eux; \
    case "$(uname -m)" in \
      x86_64|amd64)  zig_arch=x86_64-linux;  zig_sha="${ZIG_SHA256_X86_64}" ;; \
      aarch64|arm64) zig_arch=aarch64-linux; zig_sha="${ZIG_SHA256_AARCH64}" ;; \
      *) echo "no Zig ${ZIG_VERSION} build for $(uname -m)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL --retry 8 --retry-delay 5 -o /tmp/zig.tar.xz \
        "${ZIG_MIRROR}/${ZIG_VERSION}/zig-${zig_arch}-${ZIG_VERSION}.tar.xz"; \
    echo "${zig_sha}  /tmp/zig.tar.xz" | sha256sum -c -; \
    mkdir -p /opt/zig; \
    xz -dc /tmp/zig.tar.xz | tar -x -C /opt/zig --strip-components=1; \
    rm -f /tmp/zig.tar.xz; \
    ln -sf /opt/zig/zig /usr/local/bin/zig; \
    test "$(zig version)" = "${ZIG_VERSION}"

COPY mix.exs mix.lock ./
COPY apps/gitrekt/mix.exs apps/gitrekt/
COPY apps/gitgud/mix.exs apps/gitgud/
COPY apps/gitgud_web/mix.exs apps/gitgud_web/

RUN mix do deps.get --only prod, deps.compile --skip-umbrella-children

COPY apps/gitrekt/Makefile apps/gitrekt/
# `build.zig`/`build.zig.zon` are what the Makefile hands the NIF build to.
COPY apps/gitrekt/build.zig apps/gitrekt/build.zig.zon apps/gitrekt/
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

RUN npm ci --prefix apps/gitgud_web/assets --no-audit --no-fund --registry="${NPM_REGISTRY}"

RUN cd apps/gitgud_web && mix assets.deploy

# RUN mix phx.digest /build/apps/gitgud_web/priv/static

# COPY rel ./rel

RUN mix release

FROM docker.1ms.run/hexpm/elixir:$ELIXIR_VERSION-erlang-$ERLANG_VERSION-$LINUX_VERSION as app

ARG APK_MIRROR_HOST=mirrors.tuna.tsinghua.edu.cn

RUN sed -i "s/dl-cdn.alpinelinux.org/${APK_MIRROR_HOST}/g" /etc/apk/repositories
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
