{
  nixConfig.extra-substituters = [
    "https://nix-community.cachix.org"
  ];
  nixConfig.extra-trusted-public-keys = [
    "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
  ];

  description = "Lanzaboote: Secure Boot for NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable-small";

    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

    pre-commit-hooks-nix = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
      inputs.flake-compat.follows = "flake-compat";
    };

    # We only have this input to pass it to other dependencies and
    # avoid having multiple versions in our dependencies.
    flake-utils.url = "github:numtide/flake-utils";

    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.rust-overlay.follows = "rust-overlay";
      inputs.flake-utils.follows = "flake-utils";
      inputs.flake-compat.follows = "flake-compat";
    };

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };

    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
  };

  outputs = inputs@{ self, nixpkgs, crane, rust-overlay, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } ({ moduleWithSystem, ... }: {
      imports = [
        # Derive the output overlay automatically from all packages that we define.
        inputs.flake-parts.flakeModules.easyOverlay

        # Formatting and quality checks.
        inputs.pre-commit-hooks-nix.flakeModule
      ];

      flake.nixosModules.lanzaboote = moduleWithSystem (
        perSystem@{ config }:
        { ... }: {
          imports = [
            ./nix/modules/lanzaboote.nix
          ];

          boot.lanzaboote.package = perSystem.config.packages.tool;
        }
      );

      flake.nixosModules.uki = moduleWithSystem (
        perSystem@{ config }:
        { lib, ... }: {
          imports = [
            ./nix/modules/uki.nix
          ];

          boot.loader.uki.stub = lib.mkDefault "${perSystem.config.packages.fatStub}/bin/lanzaboote_stub.efi";
        }
      );

      systems = [
        "x86_64-linux"

        # Not actively tested, but may work:
        # "aarch64-linux"
      ];

      perSystem = { config, system, pkgs, ... }:
        let
          pkgs = import nixpkgs {
            system = system;
            overlays = [
              rust-overlay.overlays.default
            ];
          };

          inherit (pkgs) lib;

          uefi-rust-stable = pkgs.rust-bin.fromRustupToolchainFile ./rust/stub/rust-toolchain.toml;
          craneLib = crane.lib.x86_64-linux.overrideToolchain uefi-rust-stable;

          # Build attributes for a Rust application.
          buildRustApp = lib.makeOverridable (
            { src
            , target ? null
            , doCheck ? true
            , extraArgs ? { }
            }:
            let
              commonArgs = {
                inherit src;
                CARGO_BUILD_TARGET = target;
                inherit doCheck;

                # Workaround for https://github.com/ipetkov/crane/issues/262.
                dummyrs = pkgs.writeText "dummy.rs" ''
                  #![allow(unused)]

                  #![cfg_attr(
                    any(target_os = "none", target_os = "uefi"),
                    no_std,
                    no_main,
                  )]

                  #[cfg_attr(any(target_os = "none", target_os = "uefi"), panic_handler)]
                  fn panic(_info: &::core::panic::PanicInfo<'_>) -> ! {
                      loop {}
                  }

                  #[cfg_attr(any(target_os = "none", target_os = "uefi"), export_name = "efi_main")]
                  fn main() {}
                '';
              } // extraArgs;

              cargoArtifacts = craneLib.buildDepsOnly commonArgs;
            in
            {
              package = craneLib.buildPackage (commonArgs // {
                inherit cargoArtifacts;
              });

              clippy = craneLib.cargoClippy (commonArgs // {
                inherit cargoArtifacts;
                cargoClippyExtraArgs = "-- --deny warnings";
              });

              rustfmt = craneLib.cargoFmt (commonArgs // { inherit cargoArtifacts; });
            }
          );

          stubCrane = buildRustApp {
            src = craneLib.cleanCargoSource ./rust/stub;
            target = "x86_64-unknown-uefi";
            doCheck = false;
          };

          fatStubCrane = stubCrane.override {
            extraArgs = {
              cargoExtraArgs = "--no-default-features --features fat";
            };
          };

          stub = stubCrane.package;
          fatStub = fatStubCrane.package;

          toolCrane = buildRustApp {
            src = ./rust/tool;
            extraArgs = {
              TEST_SYSTEMD = pkgs.systemd;
              nativeCheckInputs = with pkgs; [
                binutils-unwrapped
                sbsigntool
              ];
            };
          };

          tool = toolCrane.package;

          wrappedTool = pkgs.runCommand "lzbt"
            {
              nativeBuildInputs = [ pkgs.makeWrapper ];
            } ''
            mkdir -p $out/bin

            # Clean PATH to only contain what we need to do objcopy. Also
            # tell lanzatool where to find our UEFI binaries.
            makeWrapper ${tool}/bin/lzbt $out/bin/lzbt \
              --set PATH ${lib.makeBinPath [ pkgs.binutils-unwrapped pkgs.sbsigntool ]} \
              --set LANZABOOTE_STUB ${stub}/bin/lanzaboote_stub.efi
          '';
        in
        {
          packages = {
            inherit stub fatStub;
            tool = wrappedTool;
            lzbt = wrappedTool;
          };

          overlayAttrs = {
            inherit (config.packages) tool;
          };

          checks =
            let
              nixosLib = import (pkgs.path + "/nixos/lib") { };
              runTest = module: nixosLib.runTest {
                imports = [ module ];
                hostPkgs = pkgs;
              };
            in
            {
              toolClippy = toolCrane.clippy;
              stubClippy = stubCrane.clippy;
              fatStubClippy = fatStubCrane.clippy;
              toolFmt = toolCrane.rustfmt;
              stubFmt = stubCrane.rustfmt;
            } // (import ./nix/tests/lanzaboote.nix {
              inherit pkgs;
              lanzabooteModule = self.nixosModules.lanzaboote;
            }) // (import ./nix/tests/stub.nix {
              inherit pkgs runTest;
              ukiModule = self.nixosModules.uki;
            });

          pre-commit = {
            check.enable = true;

            settings.hooks = {
              nixpkgs-fmt.enable = true;
              typos.enable = true;
            };
          };

          devShells.default = pkgs.mkShell {
            shellHook =
              let
                systemdUkify = pkgs.systemdMinimal.override {
                  withEfi = true;
                  withUkify = true;
                };
              in
              ''
                ${config.pre-commit.installationScript}
                export PATH=$PATH:${systemdUkify}/lib/systemd
              '';

            packages = [
              pkgs.uefi-run
              pkgs.openssl
              (pkgs.sbctl.override { databasePath = "pki"; })
              pkgs.sbsigntool
              pkgs.efitools
              pkgs.python39Packages.ovmfvartool
              pkgs.qemu
              pkgs.nixpkgs-fmt
              pkgs.statix
              pkgs.cargo-release
            ];

            inputsFrom = [
              config.packages.stub
              config.packages.tool
            ];

            TEST_SYSTEMD = pkgs.systemd;
          };
        };
    });
}
