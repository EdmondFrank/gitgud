const std = @import("std");

// Build definition for the `gitrekt` Erlang NIF (`priv/geef_nif.so`).
//
// This is phase 1 of the C -> Zig migration: the libgit2 bindings under `c_src/`
// are still C, but they are now compiled by Zig's bundled clang instead of the
// system compiler. That makes the artifact reproducible and cross-compilable
// (`-Dtarget=x86_64-linux-musl` produces the Alpine production build straight
// from macOS) and removes a whole class of compiler-version breakage, since
// GCC 14 and clang 20+ both promote `-Wincompatible-pointer-types` to an error.
//
// `elixir_make` still drives the build through the Makefile, which locates the
// ERTS headers (it can ask `erl`) and forwards them via `-Derts_include=...`.

const c_sources = [_][]const u8{
    "c_src/blob.c",
    "c_src/commit.c",
    "c_src/config.c",
    "c_src/diff.c",
    "c_src/geef.c",
    "c_src/graph.c",
    "c_src/index.c",
    "c_src/library.c",
    "c_src/object.c",
    "c_src/odb.c",
    "c_src/oid.c",
    "c_src/pack.c",
    "c_src/pathspec.c",
    "c_src/reference.c",
    "c_src/reflog.c",
    "c_src/repository.c",
    "c_src/revparse.c",
    "c_src/revwalk.c",
    "c_src/signature.c",
    "c_src/tag.c",
    "c_src/tree.c",
    "c_src/worktree.c",};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const erts_include = b.option(
        []const u8,
        "erts_include",
        "Directory holding erl_nif.h (the ERTS include dir)",
    ) orelse @panic("missing -Derts_include=<erts>/include");

    const lib = b.addLibrary(.{
        .name = "geef_nif",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    lib.root_module.addCSourceFiles(.{
        .files = &c_sources,
        .flags = &.{
            "-Wall",
            "-Wextra",
            "-Wno-unused-parameter",
            b.fmt("-I{s}", .{erts_include}),
        },
    });

    // libgit2 ships a `libgit2.pc`, and Zig 0.17 resolves system libraries
    // through pkg-config by default.
    lib.root_module.linkSystemLibrary("git2", .{});

    // A NIF is `dlopen`ed by the emulator and calls back into `enif_*`, so those
    // symbols must remain undefined at link time.
    lib.linker_allow_shlib_undefined = true;

    const install = b.addInstallFileWithDir(
        lib.getEmittedBin(),
        .{ .custom = "priv" },
        "geef_nif.so",
    );
    b.getInstallStep().dependOn(&install.step);
}
