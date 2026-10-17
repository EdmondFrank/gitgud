# `elixir_make` entry point for the `gitrekt` NIF (`priv/geef_nif.so`).
#
# Two build paths:
#
#   * `zig` — preferred. `build.zig` compiles `c_src/*.c` with Zig's bundled
#     clang, which is reproducible and cross-compilable (see the comment there).
#     Zig 0.17 is pinned in the repository's `.tool-versions`.
#   * the system C compiler — used when no `zig` is on `PATH` (e.g. a release
#     built on a host without Zig). This is the historical path and works again
#     now that the `-Wincompatible-pointer-types` bugs in `c_src/` are fixed.
#
# The production image always takes the first path: the Dockerfile installs Zig
# into `/usr/local/bin`.

ERLANG_PATH ?= $(shell erl -eval 'io:format("~s", [lists:concat([code:root_dir(), "/erts-", erlang:system_info(version), "/include"])])' -s init stop -noshell)

ZIG ?= $(shell command -v zig 2>/dev/null)

# `--prefix .` installs the artifact straight into `priv/geef_nif.so`, which is
# where `GitRekt.Git.load_nif/0` looks for it.
ZIG_BUILD_FLAGS ?= --prefix . -Doptimize=ReleaseFast

# Optional explicit Zig target, e.g. `ZIG_TARGET=x86_64-linux-musl`. Unset means
# "native", which is what both a local build and the container build want.
ZIG_TARGET ?=
ZIG_TARGET_FLAGS = $(if $(strip $(ZIG_TARGET)),-Dtarget=$(ZIG_TARGET),)

# Flags for the fallback (non-Zig) path only.
ifeq ($(OS),Windows_NT)
	INCLUDE_DIR ?= /usr/local/include
	LIB_DIR ?= /usr/local/lib
	CFLAGS ?= -O2 -Wall -Wextra -Wno-unused-parameter -I$(ERLANG_PATH) -I$(INCLUDE_DIR)
	LDFLAGS += -L$(LIB_DIR) -lgit2
else
	CFLAGS ?= -O2 -Wall -Wextra -Wno-unused-parameter -I$(ERLANG_PATH)
	CFLAGS += -fPIC

	ifeq ($(shell uname),Darwin)
		INCLUDE_DIR ?= /opt/homebrew/include
		LIB_DIR ?= /opt/homebrew/lib
		LDFLAGS += -dynamiclib -undefined dynamic_lookup
	else ifeq ($(shell uname),Linux)
		INCLUDE_DIR ?= /usr/include
		LIB_DIR ?= /usr/lib
		LDFLAGS += -Wl,--no-as-needed
	else
		INCLUDE_DIR ?= /usr/local/include
		LIB_DIR ?= /usr/local/lib
		LDFLAGS += -Wl,--no-as-needed
	endif

	CFLAGS += -I$(INCLUDE_DIR)
	LDFLAGS += -L$(LIB_DIR) -lgit2
endif

export INCLUDE_DIR
export LIB_DIR
export ERLANG_PATH

src = $(wildcard c_src/*.c)
hdr = $(wildcard c_src/*.h)

all: priv/geef_nif.so

ifeq ($(strip $(ZIG)),)
priv/geef_nif.so: $(src) $(hdr)
	@mkdir -p priv
	$(CC) $(CFLAGS) -shared -w $(LDFLAGS) -o $@ $(src)
else
priv/geef_nif.so: $(src) $(hdr) build.zig build.zig.zon
	$(ZIG) build $(ZIG_BUILD_FLAGS) $(ZIG_TARGET_FLAGS) -Derts_include=$(ERLANG_PATH)
endif

clean:
	$(RM) -r priv/geef_nif.so .zig-cache zig-out

.PHONY: all clean
