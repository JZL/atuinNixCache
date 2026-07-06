# atuinNixCache

Claude generated:

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

The host (`01_nixos`) already does two things:

1. Uses this flake's package instead of an inline override, in `configuration.nix`:
   ```nix
   inputs.atuinCache.packages.${pkgs.system}.atuin
   ```
   with the input declared in `01_nixos/flake.nix`:
   ```nix
   inputs.atuinCache.url = "github:JZL/atuinNixCache";
   ```
   Because the host installs *this flake's* output (built against its own pinned nixpkgs),
   the store path is identical to what CI pushed — a **guaranteed** hit, independent of the
   rest of the system's nixpkgs.

2. Adds the substituter so `nixos-rebuild` fetches instead of compiling:
   ```nix
   nix.settings = {
     substituters = [ "https://jzl-atuin.cachix.org" ];
     trusted-public-keys = [ "jzl-atuin.cachix.org-1:<public-key-from-cachix-UI>" ];
   };
   ```
   The public key is on the cache page at https://app.cachix.org/cache/jzl-atuin.

## Changing the patch

Edit `patches/atuin_patch.diff` here and push. CI rebuilds and caches the new atuin. On the
host, run `nix flake update atuinCache` (in `01_nixos/`) then `nixos-rebuild` — it picks up
the new build from the cache. One file, one place.
