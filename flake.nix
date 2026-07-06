{
  description = "Binary cache builder for a patched atuin (allow commands with a leading space to be saved).";

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

        default = atuin;
      });
    };
}
