# atuinNixCache

Claude generated:

NEED to set cache priority in cachix to 30 not 41, so this cache supersedes

Nightly [Cachix](https://cachix.org) binary-cache builder for a **patched atuin built from
upstream `main`**, and the **single source of truth** for that patched build.

The patch (`patches/atuin_patch.diff`) makes atuin save commands that start with a leading
space (upstream drops them). It's defined here once; the NixOS host consumes this flake's
output directly, so it installs the exact store path CI prebuilt → cache hit, and there is
no copy of the override to keep in sync.

## How it works

- `flake.nix` has two inputs: `nixpkgs` (`nixos-unstable`) and `atuin-upstream`
  (`github:atuinsh/atuin`). It builds **atuin's own** `packages.atuin` — the `atuin.nix`
  that lives in their tree — and `overrideAttrs` on top of it for three things: our patch,
  `doCheck = true`, and dropping the `check-update` feature. Exposed as
  `packages.x86_64-linux.atuin`.
- `atuin-upstream.inputs.nixpkgs.follows = "nixpkgs"` — atuin's flake pins its own nixpkgs,
  and `fenix` follows that in turn, so one redirect covers both. This is a tidiness measure,
  not a correctness one: see [below](#what-follows-is-and-isnt-for).
- `.github/workflows/build.yml` runs every night, `nix flake update`s both inputs to their
  current tips, builds `.#atuin`, and pushes the result to the `jzl-atuin` Cachix cache. It
  also commits the bumped `flake.lock` back.

**Recompiles only when something actually moved.** The CI job uses the `jzl-atuin` cache as
a substituter, so on nights where atuin's build closure is unchanged, `nix build` downloads
the existing path instead of recompiling. Tracking `main` does mean a real (full, ~15 min)
compile every time upstream lands a commit — that's CI minutes, never host time, since the
host still just downloads the finished path.

### Why upstream's recipe and not nixpkgs'

The obvious alternative — keep `pkgs.atuin`'s recipe and swap in mainline's source — puts a
recipe written for a *tagged release* in front of a *moving* tree, and it drifts in three
places: the pinned feature list, the `checkFlags` test-name skips, and the compiler.
`buildRustPackage` ignores `rust-toolchain.toml` and uses nixpkgs' rustc, while atuin's
`Cargo.toml` declares a hard `rust-version` floor — right now both sit at 1.97.0, so the day
atuin bumps to 1.98 that build breaks until nixos-unstable ships 1.98. Upstream's own flake
has none of these: the recipe is versioned with the source it builds, and `fenix` supplies
exactly the toolchain `rust-toolchain.toml` names.

What we give up is nixpkgs' packaging judgement, so the two bits worth keeping are restated
in `flake.nix`: `check-update` is off (upstream's flake builds with cargo's default
features, which include the phone-home updater), and the four `checkFlags` skips are copied
over since we turn tests on and upstream doesn't.

### What `follows` is and isn't for

It is tempting to think the host's nixpkgs has to match ours for the cache to hit. It
doesn't. `configuration.nix` asks for `inputs.atuinCache.packages.${pkgs.system}.atuin` —
`pkgs.system` is just the string `"x86_64-linux"`, and the package is then evaluated inside
*this* flake against *this* flake's lock. The host's nixpkgs never enters the derivation
hash, so the store path CI pushed is the store path the host wants, whatever the host tracks.

What `follows` buys is a deduplicated closure. atuin is a dynamically-linked Rust binary, so
its runtime closure is essentially glibc; if this flake pinned a different nixpkgs than the
host, the host would keep a *second* glibc alive next to the one the rest of the system uses
— downloaded from `cache.nixos.org` rather than compiled, so tens of MB of store, not build
time. Worth having, but nothing breaks without it.

### Reverting to the packaged release

Drop the `atuin-upstream` input and go back to `pkgs.atuin.overrideAttrs` with just the
patch and `doCheck` — that tracks nixpkgs' tagged atuin again, at whatever version
nixos-unstable carries.

## One-time setup

1. Create the cache at https://app.cachix.org (name: **`jzl-atuin`**).
2. Generate a push token: `cachix authtoken` (or the Cachix web UI).
3. In this repo: **Settings → Secrets and variables → Actions → New repository secret**
   - Name: `CACHIX_AUTH_TOKEN`
   - Value: the token from step 2.
4. Trigger the first run manually: **Actions → Build atuin binary cache → Run workflow**.

## Consuming from NixOS

Consuming needs **two independent pieces** on the host (`01_nixos`) — the flake input is
only the recipe; the substituter is what turns it into a download instead of a compile:

1. **The recipe** — use this flake's package instead of an inline override, in
   `configuration.nix`:
   ```nix
   inputs.atuinCache.packages.${pkgs.system}.atuin
   ```
   with the input declared in `01_nixos/flake.nix`:
   ```nix
   inputs.atuinCache.url = "github:JZL/atuinNixCache";
   ```
   Because the host installs *this flake's* output (built against its own pinned nixpkgs),
   the store path is identical to what CI pushed — a **guaranteed** hit. On its own, though,
   this would just compile atuin locally.

2. **The substituter** — where to download that store path from, in `configuration.nix`
   under the existing `nix.settings`:
   ```nix
   extra-substituters = [ "https://jzl-atuin.cachix.org" ];
   extra-trusted-public-keys = [ "jzl-atuin.cachix.org-1:<public-key-from-cachix-UI>" ];
   ```
   Use the `extra-` variants so `cache.nixos.org` stays in the list. Replace the key with
   the real one from https://app.cachix.org/cache/jzl-atuin. **Note the GitHub repo
   `atuinNixCache` is source code, not the cache — the cache is the separate
   `jzl-atuin.cachix.org` URL.**

## Staying under the 5 GB free-tier limit

Only atuin's own output is pushed (its deps are substituted from `cache.nixos.org` and not
re-uploaded), and only when atuin actually changes — so growth is ~tens of MB per change.
To keep it bounded long-term:

- Enable GC in the cache settings: **app.cachix.org → `jzl-atuin` → Settings → Garbage
  Collection**, retention e.g. 30 days. Stale old atuins age out; the current one stays
  warm because CI and `nixos-rebuild` fetch it.
- The workflow also `cachix pin`s each new build under the name `atuin`, so the latest is
  always protected from GC even if it hasn't been fetched recently.

## Changing the patch

Edit `patches/atuin_patch.diff` here and push. CI rebuilds and caches the new atuin. On the
host, run `nix flake update atuinCache` (in `01_nixos/`) then `nixos-rebuild` — it picks up
the new build from the cache. One file, one place.

Since the patch now applies to a moving `main`, it can drift: if upstream rewrites
`should_save` or the test around it, the nightly build fails at `patchPhase` (or at
`doCheck`) rather than silently producing an unpatched atuin. That's the intended failure
mode — fix the diff's context and push.
