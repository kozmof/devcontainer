# didcon
A minimum defence in depth devcontainer

## Usage

Clone this repository, then use one of the helper scripts to place or update
the .devcontainer in your project.

### Fresh install (setup.sh)
Copies .devcontainer into a project that doesn't have one yet.

```sh
git clone <this-repo> /tmp/didcon
/tmp/didcon/setup.sh /path/to/your/project
```

TARGET_DIR defaults to the current directory if omitted. The script
refuses to run if the target already has a .devcontainer, so it never
overwrites an existing setup. Use patch.sh for that.

### Update an existing one (patch.sh)
Interactively patches a project's existing .devcontainer with the latest
version from this repository.

```sh
git clone <this-repo> /tmp/didcon
/tmp/didcon/patch.sh /path/to/your/project
```

TARGET_DIR defaults to the current directory if omitted. For every file
that differs or is new, it shows a diff and asks, file by file, whether to
apply it.

```
[y]es    patch this file
[n]o     skip it (default)
[a]ll    patch this and every remaining file without asking
[q]uit   stop now
```

Nothing is overwritten without your confirmation, so answering "no"
preserves hand-crafted local changes such as custom whitelists and tweaked
policies. Files that exist only in your project are reported at the end but
never deleted.

## Language variants
devcontainer.json selects one of four Dockerfiles. Dockerfile builds a
Node-only image, Dockerfile.withGo adds Go, Dockerfile.withRust adds Rust,
and Dockerfile.withZig adds Zig.

### Rust notes
CARGO_HOME is /workspace/.cargo-home rather than ~/.cargo, the same
redirect the pnpm store uses. Landlock domains nest by intersection, so
when an agent spawns cargo the cargo sandbox can only reach paths the
agent's own policy already granted. No agent policy grants ~/.cargo, and
every one of them grants /workspace. /workspace is a bind mount, so the
crates.io index and downloaded crates also survive image rebuilds with no
volume to manage. Add .cargo-home/ to your project's .gitignore.

The name is .cargo-home rather than .cargo on purpose. Cargo discovers
project config at <ancestors>/.cargo/config.toml separately from
$CARGO_HOME/config.toml, and collapsing the two would let anything with
write access to the cache inject build flags.

island/profiles-rust/ overlays the claude-code, codex, and herdr policies
with variants that grant /opt/rust and CARGO_HOME, and Dockerfile.withRust
applies it on top of island/profiles/. The base policies cannot grant
/opt/rust unconditionally, because island warns about missing paths on
every launch in the non-Rust images. When editing an agent policy, change
both copies.

rust-toolchain.toml is ignored, since the image installs the Rust dist
tarball rather than rustup. See .devcontainer/docs/version-bumps.md.

### Zig notes
Zig's global cache is /workspace/.zig-global-cache rather than ~/.cache/zig,
for the same reason CARGO_HOME and GOCACHE are redirected: Landlock domains
nest by intersection, so when an agent spawns zig the zig sandbox can only
reach paths the agent's own policy already granted. No agent policy grants
~/.cache, and every one of them grants /workspace, which is a bind mount, so
fetched packages also survive image rebuilds. The local cache already
defaults to .zig-cache inside the project. Add both .zig-cache/ and
.zig-global-cache/ to your project's .gitignore.

The toolchain lives at /usr/local/zig, not /opt/zig, so this variant needs no
island/profiles-zig/ overlay the way Rust needs profiles-rust/. Every agent
policy already grants read and execute on /usr, which covers it — the same
reason Dockerfile.withGo needs no overlay for /usr/local/go.
security-preflight.sh asserts that the agents really can execute
/usr/local/zig/zig, so a future change to those grants surfaces at container
start rather than the first time an agent tries to build something.

One layer that exists for the other variants is missing here: Zig has no
Takumi Guard equivalent. npm installs are proxied through npm.flatt.tech and
Go module fetches through golang.flatt.tech, but zig fetch downloads straight
from whatever URLs build.zig.zon names. The hashes in build.zig.zon give
integrity and reproducibility, not vetting, so nothing screens a dependency
for known-malicious code before it reaches the build. The zig-workspace
sandbox carries proportionally more weight in this image, and ziglang.org is
whitelisted in extra-whitelist.conf alongside the GitHub domains most
dependencies resolve to. A build.zig.zon pointing anywhere else needs its host
added there.

The image ships one pinned compiler and no version manager, so a project
requiring a different Zig version means a rebuild. See
.devcontainer/docs/version-bumps.md.

## Checking a running container
```
/opt/scripts/security-preflight.sh
```

Verifies safe-chain, Takumi Guard, the registry policy, the island
profiles, the shims, and that each sandbox blocks and allows what it
should. Run it as the dev user after postCreateCommand finishes.

## Host control surfaces
The standard configuration bind-mounts .devcontainer, .git/config, and
.git/hooks read-only inside the container. This prevents an agent or package
hook from persisting code that would execute during a later host-side rebuild
or Git command, while leaving the Git index and refs writable for normal
commits.

These protective mounts assume a conventional checkout with a .git directory.
Git worktrees, where .git is a file, need equivalent host-side read-only
mounts adapted to their actual Git directory.

This blocks the most direct hook and rebuild-persistence paths, but it does not
turn a writable host checkout into a hostile-code boundary. An agent can still
change project scripts that a user later runs on the host. For fully untrusted
repositories, clone into a container volume and export only reviewed patches.
The DNS resolver and VS Code/X11 sockets are also integration channels rather
than security boundaries. Remove or proxy them when the threat model includes
data exfiltration or hostile container processes.
