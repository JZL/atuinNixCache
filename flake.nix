{
  description = "Binary cache builder for a patched atuin, built from upstream main (allow commands with a leading space to be saved).";

  inputs = {
    # Track nixos-unstable (the NixOS "nightly" — same branch the consuming system must use
    # for the store paths here to match and land as cache hits). nixos-unstable is gated on
    # the NixOS test suite, unlike the rawer nixpkgs-unstable.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # atuin mainline, built with atuin's *own* packaging (its in-tree atuin.nix, exposed as
    # packages.atuin). The recipe therefore moves with the source: no feature list or test
    # name pinned here can drift away from main. It also builds via fenix against the
    # rust-toolchain.toml pin, so a mainline rustc bump doesn't have to wait for
    # nixos-unstable to ship the matching compiler.
    #
    # `follows` points it at our nixpkgs (fenix follows nixpkgs inside atuin's flake in
    # turn, so one redirect covers both). This is *not* what makes the cache hit work — the
    # host evaluates this flake's package against this flake's lock, so the store path is
    # decided here regardless. It only keeps the runtime closure deduplicated: without it
    # the host would carry a second glibc, from atuin's nixpkgs pin, next to the one the
    # rest of the system already uses.
    atuin-upstream = {
      url = "github:atuinsh/atuin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, nixpkgs, atuin-upstream }:
    let
      # The NixOS host (ovh-vps) is x86_64-linux; add more here if other machines consume the cache.
      systems = [ "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems f;

      # atuin's default features minus check-update (the "a new version is available"
      # phone-home, which is meaningless on a Nix-managed install — same call nixpkgs makes).
      # `hex` is upstream's alias for pty-proxy.
      features = [
        "ai"
        "client"
        "clipboard"
        "daemon"
        "hex"
        "sync"
      ];
    in
    {
      packages = forAllSystems (system: rec {
        # Single source of truth for the patched atuin. The NixOS host consumes this exact
        # output (01_nixos/configuration.nix -> inputs.atuinCache.packages.<system>.atuin),
        # so whatever CI builds and pushes here is byte-identical to what the host installs.
        # Edit patches/atuin_patch.diff to change behaviour; the host picks it up on
        # `nix flake update atuinCache`.
        atuin = atuin-upstream.packages.${system}.atuin.overrideAttrs (
          finalAttrs: previousAttrs: {
            # Upstream's derivation is just `name = "atuin"`; say which atuin it is.
            name = "atuin-0-unstable-${atuin-upstream.shortRev}";

            patches = (previousAttrs.patches or [ ]) ++ [
              ./patches/atuin_patch.diff
            ];

            # These are plain derivation attrs read by cargo-build-hook.sh, so overrideAttrs
            # reaches them. `buildFeatures` would not — buildRustPackage folds that into the
            # build flags at its call site, which already happened inside atuin's flake.
            cargoBuildNoDefaultFeatures = true;
            cargoBuildFeatures = features;

            # Upstream ships doCheck = false. Run the tests anyway: the patch edits
            # should_save and the assertion covering it, so a silent semantic drift on main
            # (rather than a clean patch-apply failure) is exactly what tests would catch.
            doCheck = true;
            cargoCheckNoDefaultFeatures = true;
            cargoCheckFeatures = features;
            preCheck = ''
              export HOME=$(mktemp -d)
            '';
            checkFlags = [
              # Same skips nixpkgs applies: these want network, a writable system, or a real user.
              "--skip=registration"
              "--skip=sync"
              "--skip=change_password"
              "--skip=multi_user_test"
            ];
          }
        );

        default = atuin;
      });
    };
}
