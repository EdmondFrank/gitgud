ARG ELIXIR_VERSION=1.18.2
ARG ERLANG_VERSION=27.3
ARG ALPINE_VERSION=3.21.3
ARG LINUX_VERSION=alpine-$ALPINE_VERSION

FROM docker.1ms.run/hexpm/elixir:$ELIXIR_VERSION-erlang-$ERLANG_VERSION-$LINUX_VERSION as build

# --- Zig: the C toolchain that builds the `gitrekt` NIF ----------------------
# `apps/gitrekt/build.zig` compiles `c_src/*.c` into `priv/geef_nif.so` with Zig's
# bundled clang, which sidesteps the GCC 14 / clang 20+ `-Wincompatible-pointer-types`
# breakage. Zig comes from a release rather than `apk add zig` because Alpine only
# ships zig <= 0.16 (3.21 has 0.13.0) and `build.zig` requires 0.17; the Linux
# releases are statically linked, so they run unchanged on musl.
#
# Two interchangeable, sha256-verified sources (installed by the step below):
#   * the official tarball from `ZIG_MIRROR`, pinned by `ZIG_SHA256_*` (default), and
#   * the arch-matching `ziglang` wheel from the PyPI mirror in `ZIG_PIP_INDEX`
#     (opt-in; the wheel carries the same `zig` + `lib/` as the tarball). PyPI is
#     mirrored inside China while ziglang.org is Cloudflare-throttled to a few tens
#     of KB/s from CN build hosts, so the wheel is the faster path there. A
#     host-local proxy also works without touching this file — see the step below.
ARG ZIG_VERSION=0.17.0
ARG ZIG_MIRROR=https://ziglang.org/download
ARG ZIG_SHA256_X86_64=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026
ARG ZIG_SHA256_AARCH64=9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8
# e.g. https://mirrors.cloud.tencent.com/pypi/simple ; empty -> tarball above
ARG ZIG_PIP_INDEX=
ARG ZIG_WHEEL_SHA256_X86_64=97079827064a7492cce5541ceb438ae8003ce1e54e399676da2d62fb7a5dc08b
ARG ZIG_WHEEL_SHA256_AARCH64=d2804f94f54f7fcf8169f4b212a619ad688a4e2e6592e976f0cf2e58e2cd8af3

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
# tarball and `unzip` the optional `ziglang` wheel. `build-base` is still required:
# the other C extensions (`argon2_elixir`, `cmark`) keep compiling with the system
# compiler.
RUN apk add --no-cache build-base erlang-dev libgit2-dev git nodejs npm curl pkgconf unzip xz && \
    curl -fsSL --retry 8 --retry-delay 5 -o /tmp/hex.ez "${HEX_BUILDS_URL}/installs/1.16.0/hex-2.5.3.ez" && \
    curl -fsSL --retry 8 --retry-delay 5 -o /tmp/rebar3 "${HEX_BUILDS_URL}/installs/1.15.0-rc.0/rebar3-3.22.0" && \
    mix archive.install /tmp/hex.ez --force && \
    mix local.rebar rebar3 /tmp/rebar3 --force

# sha256-verified Zig install; `zig version` doubles as a smoke test. The wheel
# path reads the href straight out of the PyPI simple index (it may be relative,
# hence `resolve`) and then verifies the download against its `#sha256=` fragment.
# No Dockerfile change is needed to route the build through a host-local proxy:
# `--build-arg HTTPS_PROXY=http://10.7.0.21:7890` works because Docker treats the
# proxy variables as predefined build args (they are never persisted in the image).
RUN set -eux; \
    case "$(uname -m)" in \
      x86_64|amd64)  zig_arch=x86_64-linux;  zig_pip_arch=x86_64; \
                     zig_sha="${ZIG_SHA256_X86_64}"; wheel_sha="${ZIG_WHEEL_SHA256_X86_64}" ;; \
      aarch64|arm64) zig_arch=aarch64-linux; zig_pip_arch=aarch64; \
                     zig_sha="${ZIG_SHA256_AARCH64}"; wheel_sha="${ZIG_WHEEL_SHA256_AARCH64}" ;; \
      *) echo "no Zig ${ZIG_VERSION} build for $(uname -m)" >&2; exit 1 ;; \
    esac; \
    resolve() { \
        base="$1"; href="$2"; \
        case "$href" in \
            http://*|https://*) printf %s "$href"; return ;; \
            /*) origin=$(printf %s "$base" | cut -d/ -f1-3); printf %s "$origin$href"; return ;; \
        esac; \
        while [ "${href#../}" != "$href" ]; do \
            href="${href#../}"; base="${base%/}"; base="${base%/*}/"; \
        done; \
        printf %s "${base}${href}"; \
    }; \
    mkdir -p /opt/zig; \
    if [ -n "${ZIG_PIP_INDEX}" ]; then \
        index="${ZIG_PIP_INDEX%/}/ziglang/"; \
        curl -fsSL --retry 8 --retry-delay 5 -o /tmp/zig-index.html "$index"; \
        grep -o 'href="[^"]*"' /tmp/zig-index.html > /tmp/zig-hrefs || :; \
        sed 's/^href="//; s/"$//' /tmp/zig-hrefs > /tmp/zig-hrefs.clean; \
        grep "musllinux_1_1_${zig_pip_arch}\.whl" /tmp/zig-hrefs.clean > /tmp/zig-hrefs.arch || :; \
        grep -F "ziglang-${ZIG_VERSION}-" /tmp/zig-hrefs.arch > /tmp/zig-hrefs.ver || :; \
        href=$(head -n 1 /tmp/zig-hrefs.ver); \
        [ -n "$href" ] || { echo "no ${ZIG_VERSION} wheel for musllinux_1_1_${zig_pip_arch} at $index" >&2; exit 1; }; \
        case "${href##*#}" in sha256=*) wheel_sha="${href##*#sha256=}" ;; esac; \
        wheel_href="${href%%#*}"; \
        wheel_url=$(resolve "$index" "$wheel_href"); \
        curl -fsSL --retry 8 --retry-delay 5 -o /tmp/zig.whl "$wheel_url"; \
        echo "${wheel_sha}  /tmp/zig.whl" | sha256sum -c -; \
        unzip -q /tmp/zig.whl -d /tmp/zig-wheel; \
        cp -a /tmp/zig-wheel/ziglang/. /opt/zig/; \
        rm -rf /tmp/zig-wheel /tmp/zig.whl /tmp/zig-index.html /tmp/zig-hrefs*; \
    else \
        curl -fsSL --retry 8 --retry-delay 5 -o /tmp/zig.tar.xz \
            "${ZIG_MIRROR}/${ZIG_VERSION}/zig-${zig_arch}-${ZIG_VERSION}.tar.xz"; \
        echo "${zig_sha}  /tmp/zig.tar.xz" | sha256sum -c -; \
        xz -dc /tmp/zig.tar.xz | tar -x -C /opt/zig --strip-components=1; \
        rm -f /tmp/zig.tar.xz; \
    fi; \
    chmod +x /opt/zig/zig; \
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
