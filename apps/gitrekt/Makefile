ERLANG_PATH ?= $(shell erl -eval 'io:format("~s", [lists:concat([code:root_dir(), "/erts-", erlang:system_info(version), "/include"])])' -s init stop -noshell)

# Set default INCLUDE_DIR and LIB_DIR if not provided
ifeq ($(OS),Windows_NT)
	INCLUDE_DIR ?= /usr/local/include
	LIB_DIR ?= /usr/local/lib
	CFLAGS ?= -O2 -Wall -Wextra -Wno-unused-parameter -I$(ERLANG_PATH) -I$(INCLUDE_DIR)
	LDFLAGS += -L$(LIB_DIR) -lgit2
else
	CFLAGS ?= -O2 -Wall -Wextra -Wno-unused-parameter -I$(ERLANG_PATH)
	CFLAGS += -fPIC

	# Platform-specific settings
	ifeq ($(shell uname),Darwin)
		INCLUDE_DIR ?= /opt/homebrew/include
		LIB_DIR ?= /opt/homebrew/lib
		LDFLAGS += -dynamiclib -undefined dynamic_lookup
	else ifeq ($(shell uname),Linux)
		INCLUDE_DIR ?= /usr/include
		LIB_DIR ?= /usr/lib
		LDFLAGS += -Wl,--no-as-needed
	else
		# Default for other Unix-like systems
		INCLUDE_DIR ?= /usr/local/include
		LIB_DIR ?= /usr/local/lib
		LDFLAGS += -Wl,--no-as-needed
	endif

	CFLAGS += -I$(INCLUDE_DIR)
	LDFLAGS += -L$(LIB_DIR) -lgit2
endif

export INCLUDE_DIR
export LIB_DIR

src = $(wildcard c_src/*.c)
obj = $(src:.c=.o)

all: priv/geef_nif.so

priv/geef_nif.so: $(src)
	@mkdir -p priv
	$(CC) $(CFLAGS) -shared -w $(LDFLAGS) -o $@ $^

clean:
	$(RM) -r $(obj) priv/geef_nif.so

.PHONY: clean
