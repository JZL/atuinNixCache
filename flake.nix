{
  description = "Binary cache builder for a patched atuin (allow commands with a leading space to be saved) and for terraform (unfree, so never prebuilt by Hydra).";

  # Track nixos-unstable (the NixOS "nightly" — same branch the consuming system must use
  # for the store paths here to match and land as cache hits). nixos-unstable is gated on
  # the NixOS test suite, unlike the rawer nixpkgs-unstable.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      # The NixOS host (ovh-vps) is x86_64-linux; add more here if other machines consume the cache.
      systems = [ "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # terraform is unfree (BUSL-1.1 since 1.6), and `nixpkgs.legacyPackages` carries the
      # default config (allowUnfree = false), so it refuses to evaluate there. Setting the
      # config *inside* the flake is pure -- that is what removes the need for
      # `NIXPKGS_ALLOW_UNFREE=1 ... --impure` at the call site. allowUnfree is an
      # evaluation-time licence check only; it is not an input to any derivation, so store
      # paths built through this instance are identical to ones built any other way.
      unfreePkgsFor = system: import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
    in
    {
      packages = forAllSystems (pkgs: rec {
        # Single source of truth for the patched atuin. The NixOS host consumes this exact
        # output (01_nixos/configuration.nix -> inputs.atuinCache.packages.<system>.atuin),
        # so whatever CI builds and pushes here is byte-identical to what the host installs.
        # Edit patches/atuin_patch.diff to change behaviour; the host picks it up on
        # `nix flake update atuinCache`.
        atuin = pkgs.atuin.overrideAttrs (
          finalAttrs: previousAttrs: {
            doCheck = true;
            patches = (previousAttrs.patches or [ ]) ++ [
              ./patches/atuin_patch.diff
            ];
          }
        );

        # Unpatched stock terraform -- the point here is purely the binary cache, not a
        # source change. Because it is unfree it is absent from cache.nixos.org, so every
        # `nix shell nixpkgs#terraform` compiles the whole Go tree locally. CI builds it
        # once a night and pushes it here, and callers use:
        #     nix shell github:JZL/atuinNixCache#terraform
        # which pins this flake's flake.lock -- the same nixpkgs CI built against, so the
        # store path matches and it downloads instead of compiling. No --impure needed.
        terraform = (unfreePkgsFor pkgs.system).terraform;

        default = atuin;
      });
    };
}
