# Bumping pinned tool versions

Every agent, package manager, and downloaded binary in this devcontainer is
installed at **build time**, then left root-owned. Claude Code and Codex track
the npm `latest` dist-tag by default; the remaining listed tools are pinned. The dev user
cannot overwrite these binaries, so none of them can self-update from inside a
running container — updating is done by editing a pinned version and rebuilding
the image.

This is deliberate. Root-owned tool binaries are the enforcement assets the
sandbox model depends on; letting a running process replace them would defeat
that model. The trade-off is that "update from within" never works, so each
tool's self-update path is either blocked or, where the tool prompts for it,
switched off (see [Codex](#codex) below).

## Where each version lives

All knobs are `ARG`s near the top of each Dockerfile. The four variants
(`Dockerfile`, `Dockerfile.withGo`, `Dockerfile.withRust`, `Dockerfile.withZig`)
share the same core set and must be kept in sync — bump the same value in every
variant you build.

| Tool | ARG(s) | Default | Notes |
|---|---|---|---|
| Claude Code | `CLAUDE_CODE_VERSION` | `latest` | npm latest dist-tag |
| Codex | `CODEX_VERSION` | `latest` | npm latest dist-tag |
| npm | `NPM_VERSION` | `11.17.0` | |
| island | `ISLAND_REV` | git SHA | Built from source; pin a full commit SHA |
| herdr | `HERDR_VERSION` + `HERDR_SHA256` | `0.7.4` | Optional (`INSTALL_HERDR`); verified download |
| Go (`.withGo`) | `GO_VERSION` + `GO_SHA256` | `1.24.2` | Verified download |
| Rust (`.withRust`) | `RUST_VERSION` + `RUST_SHA512` | `1.96.0` | Verified download |
| Zig (`.withZig`) | `ZIG_VERSION` + `ZIG_SHA256` | `0.16.0` | Verified download |

`CLAUDE_CODE_VERSION`, `CODEX_VERSION`, `NPM_VERSION`, `ISLAND_REV`, and
`INSTALL_HERDR` are also surfaced as build args in
[`devcontainer.json`](../devcontainer.json), so the common bumps can be made
there without editing the Dockerfile.

## The base image is not pinned

Everything in the table above is pinned. The base image is not: all four
variants build `FROM cgr.dev/chainguard/node:latest-dev`, because the
pinned-major tags (`node:26-dev` and friends) need a paid Chainguard plan.

That matters more than an unpinned tag usually does. `apk add` installs
packages built against the apk repo's *current* glibc, so a base image that has
been sitting in the local Docker cache can be too old to run them. Chainguard
publishes a new glibc major under a **new package name** (`glibc-2.44`, not a
newer version of `glibc`), and their images pin exact versions in
`/etc/apk/world` — so `apk upgrade` cannot close the gap, and neither can
naming `glibc` in the install. The stale image simply cannot be repaired.

The failure is quiet. The build succeeds and the breakage waits until runtime:

```
jq: /usr/lib/libm.so.6: version `GLIBC_2.44' not found (required by /usr/lib/libjq.so.1)
```

`devcontainer.json` therefore passes `--pull` in `build.options`, so the tag is
re-resolved on every build. The cost is a registry check per build and a full
rebuild of the layers after `FROM` whenever Chainguard bumps the base; the
`island-builder` stage sits on a different base and is not invalidated by it.

If you build a Dockerfile directly rather than through `devcontainer.json`,
pass `--pull` yourself:

```
docker build --pull -f .devcontainer/Dockerfile .devcontainer
```

For a reproducible image, resolve `latest-dev` to a digest and pin that instead
— but then re-resolve it deliberately, rather than letting the cache decide.

## Bumping an npm tool (Claude Code, Codex, npm)

1. Edit the version in `devcontainer.json` (or the `ARG` in each Dockerfile).
   Prefer an exact version over `latest` for a reproducible image.
2. Rebuild the container ("Dev Containers: Rebuild Container", or
   `docker build`).

Note the registry policy in [`.npmrc`](../.npmrc): installs go through
`npm.flatt.tech` with `min-release-age=7`, so a version published in the last
7 days is not yet installable. If a fresh release fails to resolve, that delay
is why — wait it out rather than working around it.

## Bumping a verified-download binary (island, herdr, Go, Rust)

These are fetched by URL and checked against a pinned hash, so the hash must be
updated together with the version or the build fails by design.

1. Update the version `ARG`.
2. Update the matching hash `ARG` (`*_SHA256` / `*_SHA512`) to the new
   release's published checksum.
3. Rebuild.

Zig publishes both in one place. `https://ziglang.org/download/index.json` lists
every release; the `x86_64-linux` entry under a version carries the tarball URL
and its `shasum`, which is exactly the `ZIG_SHA256` value:

```
curl -s https://ziglang.org/download/index.json | jq -r '."0.16.0"."x86_64-linux".shasum'
```

island is the exception: it is built from source at a pinned `ISLAND_REV`
commit SHA, so there is no separate hash — pin a full 40-character SHA rather
than a branch or tag. The SHA pins island's own source but not its crate
dependencies: upstream publishes no `Cargo.lock`, so cargo resolves them at
build time and two builds of the same SHA can pick up different patch releases.

## Rust

`RUST_VERSION` is the whole story: this image ships the dist tarball, not
rustup, so **a project's `rust-toolchain.toml` is silently ignored**. Cargo uses
the baked-in toolchain and says nothing about the mismatch. `cargo fmt` and
`cargo clippy` come from the same tarball and are asserted at build time.

To honour a project's pin, rebuild with both args from that release's
`.sha512` file on `static.rust-lang.org`:

```
--build-arg RUST_VERSION=1.97.0 --build-arg RUST_SHA512=<hash>
```

`security-preflight.sh` compares `rust-toolchain.toml` against the installed
`rustc` and warns on a mismatch, so the drift shows up at container start
rather than as a confusing build error.

## Zig

`ZIG_VERSION` is the whole story, as it is for Rust: the image ships one pinned
compiler and there is no version manager to switch it. A project whose
`build.zig.zon` declares a `minimum_zig_version` above the installed compiler
fails at build time with Zig's own error, which at least names the problem
plainly — rebuild with a matching `ZIG_VERSION` and `ZIG_SHA256`.

Pin a tagged release rather than a `master` build. Nightly tarballs live under
`ziglang.org/builds/` and are deleted as newer ones appear, so a `master` pin
turns into a 404 within days and breaks the image rebuild.

## Codex

Codex prompts to self-update on startup and, if accepted, runs
`npm install -g @openai/codex`. That install targets the root-owned global
prefix and fails with `EACCES` for the dev user — the update can never
succeed. To stop Codex offering it, the image seeds `config.toml` in Codex's
config home with:

```toml
check_for_update_on_startup = false
```

This is Codex's own setting for centrally-managed installs, which is exactly
what this image is. Bump Codex the same way as any other npm tool — via
`CODEX_VERSION` — and the update prompt stays off across rebuilds.
