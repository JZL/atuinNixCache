# atuinNixCache

Claude generated:

NEED to set cache priority in cachix to 30 not 41, so this cache supersedes

Nightly [Cachix](https://cachix.org) binary-cache builder for two packages that nothing
upstream will prebuild for us:

| output | why it's here |
| --- | --- |
| `atuin` | **patched**, so no upstream build exists. This repo is the single source of truth for the patch. |
| `terraform` | **unfree** (BUSL-1.1 since 1.6), so Hydra never builds it and `cache.nixos.org` has nothing — every plain `nix shell nixpkgs#terraform` is a full Go compile. |

The atuin patch (`patches/atuin_patch.diff`) makes atuin save commands that start with a
leading space (upstream drops them). It's defined here once; the NixOS host consumes this
flake's output directly, so it installs the exact store path CI prebuilt → cache hit, and
there is no copy of the override to keep in sync. terraform is *unmodified* stock nixpkgs
— the only point of having it here is the cache.

(The repo and cache are still named for atuin for historical reasons; renaming the Cachix
cache would change its URL and public key everywhere they're pinned, so it stays.)

## How it works

- `flake.nix` overrides `nixpkgs.atuin` with the patch and `doCheck = true`, tracking
  `nixos-unstable`, and exposes it as `packages.x86_64-linux.atuin`. It also exposes
  `packages.x86_64-linux.terraform` via a second nixpkgs instance imported with
  `config.allowUnfree = true`.
- `.github/workflows/build.yml` runs every night, `nix flake update`s to the current tip
  of `nixos-unstable`, builds `.#atuin` and `.#terraform`, and pushes both to the
  `jzl-atuin` Cachix cache. It also commits the bumped `flake.lock` back.

**No wasteful nightly recompiles.** The CI job uses the `jzl-atuin` cache as a substituter,
so on nights where a build closure is unchanged, `nix build` downloads the existing path
instead of recompiling — nothing new is built or pushed. Each package only rebuilds when
its inputs actually change on `nixos-unstable`, which is exactly when a fresh build is
needed.

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

## Using terraform (ad hoc, not installed system-wide)

```bash
nix shell github:JZL/atuinNixCache#terraform
```

Replaces the old `export NIXPKGS_ALLOW_UNFREE=1; nix shell nixpkgs#terraform --impure`,
which recompiled terraform from source basically every time. Two separate reasons it did:

1. **Unfree → never cached.** Hydra does not build unfree packages, so terraform is not on
   `cache.nixos.org` at any nixpkgs revision. Source build, always.
2. **`nixpkgs#...` is the flake registry**, whose nixpkgs pin drifts on its own schedule
   and is unrelated to the host's. Each time it moved, the store path changed and you paid
   for a rebuild even setting aside (1).

The new form fixes both: it pins *this repo's* `flake.lock` — the exact nixpkgs CI built
against — so the store path matches what was pushed, and the substituter below turns it
into a download. `--impure` and `NIXPKGS_ALLOW_UNFREE` are gone because `allowUnfree` is
set inside `flake.nix`, where it is a pure evaluation-time licence check rather than an
env-var read.

This needs the `jzl-atuin` substituter configured on the machine — on `ovh-vps` that is
already global in `configuration.nix` (`nix.settings.extra-substituters`), so it applies to
every user and every `nix shell`. On a machine without it, add `--option` flags as in
`configuration.nix`'s comment, or it silently falls back to compiling.

Optional shorthand — register it once, then `nix shell tf#terraform`:

```bash
nix registry add tf github:JZL/atuinNixCache
```

**Note on licensing:** BUSL-1.1 permits copying and redistribution for non-production /
non-competing use, which is what this is, but `jzl-atuin` is a *public* Cachix cache, so
those terraform binaries are world-readable. If that ever matters, the friction-free
alternative is `pkgs.opentofu` (MPL-2.0, the fork of terraform 1.5.x) — it's free, so
Hydra prebuilds it and `nix shell nixpkgs#opentofu` is already an instant download with no
cache of our own. It is a drop-in CLI (`tofu`), though provider hashes in
`.terraform.lock.hcl` differ since it resolves against its own registry.

## Staying under the 5 GB free-tier limit

Only our own outputs are pushed (deps are substituted from `cache.nixos.org` and not
re-uploaded), and only when they actually change — so growth is ~tens of MB per atuin
change and ~100 MB per terraform change (it's a large Go binary). Watch this now that
terraform is in the mix; it is the bigger of the two by some margin. To keep it bounded
long-term:

- Enable GC in the cache settings: **app.cachix.org → `jzl-atuin` → Settings → Garbage
  Collection**, retention e.g. 30 days. Stale old atuins age out; the current one stays
  warm because CI and `nixos-rebuild` fetch it.
- The workflow also `cachix pin`s each new build (pin names `atuin` and `terraform`), so
  the latest of each is always protected from GC even if it hasn't been fetched recently.

## Changing the patch

Edit `patches/atuin_patch.diff` here and push. CI rebuilds and caches the new atuin. On the
host, run `nix flake update atuinCache` (in `01_nixos/`) then `nixos-rebuild` — it picks up
the new build from the cache. One file, one place.
