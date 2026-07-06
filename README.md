# atuinNixCache

Claude generated:

NEED to set cache priority in cachix to 30 not 41, so this cache supersedes

Nightly [Cachix](https://cachix.org) binary-cache builder for a **patched atuin**, and the
**single source of truth** for that patched build.

The patch (`patches/atuin_patch.diff`) makes atuin save commands that start with a leading
space (upstream drops them). It's defined here once; the NixOS host consumes this flake's
output directly, so it installs the exact store path CI prebuilt → cache hit, and there is
no copy of the override to keep in sync.

## How it works

- `flake.nix` overrides `nixpkgs.atuin` with the patch and `doCheck = true`, tracking
  `nixos-unstable`, and exposes it as `packages.x86_64-linux.atuin`.
- `.github/workflows/build.yml` runs every night, `nix flake update`s to the current tip
  of `nixos-unstable`, builds `.#atuin`, and pushes the result to the `jzl-atuin` Cachix
  cache. It also commits the bumped `flake.lock` back.

**No wasteful nightly recompiles.** The CI job uses the `jzl-atuin` cache as a substituter,
so on nights where atuin's build closure is unchanged, `nix build` downloads the existing
path instead of recompiling — nothing new is built or pushed. atuin only rebuilds when its
inputs actually change on `nixos-unstable`, which is exactly when a fresh build is needed.

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
