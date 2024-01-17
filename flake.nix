{
  description = "Tmkms";

  inputs = {
    naersk.url = "github:nix-community/naersk";
    nixpkgs-mozilla.url = "github:mozilla/nixpkgs-mozilla";
    nixpkgs.url = "nixpkgs/nixos-unstable";
    utils.url = "github:numtide/flake-utils";
  };

  outputs = { naersk, nixpkgs, self, utils, nixpkgs-mozilla }:
    utils.lib.eachDefaultSystem (system:
      let
        version = (builtins.substring 0 8 self.lastModifiedDate) + "-"
          + (if self ? rev then builtins.substring 0 7 self.rev else "dirty");

        pkgs = import nixpkgs {
          inherit system;
          overlays = [ (import nixpkgs-mozilla) ];
        };

        toolchain = (pkgs.rustChannelOf {
          rustToolchain = ./rust-toolchain.toml;
          sha256 = "sha256-rLP8+fTxnPHoR96ZJiCa/5Ans1OojI7MLsmSqR2ip8o=";
        }).rust;

        naersk' = pkgs.callPackage naersk {
          cargo = toolchain;
          rustc = toolchain;
        };

        buildInputs = [ pkgs.openssl pkgs.postgresql_12.lib ]
          ++ pkgs.lib.optional pkgs.stdenv.isDarwin [
            pkgs.libiconv
            pkgs.darwin.apple_sdk.frameworks.SystemConfiguration
          ];
        nativeBuildInputs = [
          pkgs.pkg-config
          pkgs.postgresql_12
          pkgs.sqlx-cli
        ];

        projectCargo = { description, cargoCommand }:
          naersk'.buildPackage {
            inherit description buildInputs nativeBuildInputs;

            src = pkgs.lib.sourceFilesBySuffices ./. [
              ".css"
              ".psql"
              ".rs"
              ".sql"
              "Cargo.lock"
              "Cargo.toml"
              "upgrade-watcher.toml"
            ];

            # Deny warnings.
            RUSTFLAGS = "-D warnings";

            # Ensure we have pretty output, even on CI.
            CARGO_TERM_COLOR = "always";

            # Override the build command so we make the build logs part of the output.
            # This way we can print test output, even if running the tests was a no-op
            # and we got the results from a cache. We don't use the `cargoTestCommands`
            # feature of Naersk, because that builds everything first, but for e.g.
            # Clippy, we don't need to compile first, it only wastest time.
            cargoBuild = _:
              "mkdir -p $out/log && cargo $cargo_options ${cargoCommand} 2>&1 | tee $out/log/build.ansi";

            # The tests invoke these Python scripts, and they contain a /usr/bin/env
            # line which needs to be changed to a Nix store path to be able to
            # execute these scripts from the build sandbox.
            # patchPhase = ''
            #   patchShebangs --build tools/*.py client/*.py
            # '';

            # Normally Naersk copies the binaries out for us, but I messed with the
            # options to get the build logs out too, which breaks copying the binary
            # so we do it ourselves.
            installPhase = ''
              mkdir -p $out/bin target/release
              find target/release -maxdepth 1 -executable -type f -execdir cp '{}' $out/bin ';'
            '';
          };

        # Vaultenv is packaged in Nixpkgs, however it still ships an old version
        # without Kubernetes auth. Instead, fetch the static binary. (Building
        # from source is kind of a pain ...). On systems where we don't have the
        # prebuilt binary, use the packaged older version.
        # vaultenv = if system != "x86_64-linux" then
        #   pkgs.vaultenv
        # else
        #   pkgs.stdenv.mkDerivation rec {
        #     pname = "vaultenv";
        #     version = "0.15.1";
        #     src = builtins.fetchurl {
        #       url =
        #         "https://github.com/channable/vaultenv/releases/download/v${version}/vaultenv-${version}-linux-musl";
        #       sha256 =
        #         "sha256:0k8b4cl59g665c925z05cahzk6ri7an12lhw0aiilr84bbnivqc8";
        #     };
        #     phases = [ "installPhase" ];
        #     installPhase = ''
        #       mkdir -p $out/bin
        #       cp $src $out/bin/vaultenv
        #       chmod +x $out/bin/vaultenv
        #     '';
        #     meta = {
        #       homepage = "https://github.com/channable/vaultenv";
        #       description =
        #         "Launch processes with Vault secrets in the environment";
        #       platforms = [ "x86_64-linux" ];
        #       license = pkgs.lib.licenses.bsd3;
        #     };
        #   };

        # githubActionsConfig = let
        #   workflow = builtins.toJSON ((import ./.github/workflows/build.nix) {
        #     inherit self;
        #     # We run GitHub actions on x64 Linux.
        #     system = "x86_64-linux";
        #   });
        #   preamble = ''
        #     # This file is generated from build.nix.
        #     # To re-generate it, run
        #     #
        #     #   nix build .#githubActionsConfig --out-link result
        #     #   cp result .github/workflows/build.yml
        #     #
        #     # with Nix 2.10 in the root of the repository.
        #   '';
        # in pkgs.runCommand "build.yml" {
        #   inherit preamble workflow;
        #   buildInputs = [ pkgs.jq ];
        # } ''
        #   # Pipe it through jq to make diffs more human-friendly.
        #   echo "$preamble" > $out;
        #   echo "$workflow" | jq . >> $out;
        # '';

        # All the .py files in the repository. We extract them into a separate
        # derivation such that the Python checks don't have to be re-executed on
        # every commit if we did not change any Python files.
        # pythonSourceFiles = pkgs.lib.sourceFilesBySuffices ./. [ ".py" ];

      in rec {
        devShells = {
          default = pkgs.mkShell {
            nativeBuildInputs = [
              toolchain
              # vaultenv
            ] ++ buildInputs ++ nativeBuildInputs;

            # Set a few environment variables that are useful for running locally.
            DATABASE_URL = "postgresql:///upgrade_watcher";
            PGDATABASE = "upgrade_watcher";
            PGPASSWORD = "upgrade_watcher_app";
            PGUSER = "upgrade_watcher_app";
            SQLX_OFFLINE = "true";

            RUST_SRC_PATH = pkgs.rustPlatform.rustLibSrc;
          };
        };

        checks = rec {
          test = projectCargo {
            description = "Run tests";
            cargoCommand = "test";
          };

          # Note, --tests means "also lint the tests", not "only lint the tests".
          clippy = projectCargo {
            description = "Run Clippy";
            cargoCommand = "clippy --tests";
          };

          # Note, instead of definining another crate to build and overriding the test command
          # to run "cargo fmt", we run it directly. If we would override the test command, then
          # if building fails, we would not run the style check.
          fmt-rust = {
            description = "Check Rust formatting";
          } // pkgs.runCommand "check-fmt-rust" {
            buildInputs = [ toolchain ];
          } ''
            cargo fmt --manifest-path ${./.}/Cargo.toml -- --check
            mkdir -p $out/log
            echo "fmt ok" > $out/log/build.ansi
          '';

          # fmt-python = {
          #   description = "Check Python formatting";
          # } // pkgs.runCommand "check-fmt-python" {
          #   buildInputs = [ pkgs.black ];
          # } ''
          #   mkdir -p $out/log
          #   black --check --diff --color ${pythonSourceFiles} | tee $out/log/build.ansi
          # '';

          # typecheck-python = {
          #   description = "Typecheck Python code";
          # } // pkgs.runCommand "typecheck-python" {
          #   buildInputs = [ pkgs.mypy ];
          # } ''
          #   mkdir -p $out/log
          #   mypy --strict --color-output ${pythonSourceFiles} | tee $out/log/build.ansi
          # '';

          # actions = {
          #   description = "Confirm that GitHub Actions config is up to date";
          # } // pkgs.runCommand "check-actions" { } ''
          #   diff --unified ${
          #     ./.
          #   }/.github/workflows/build.yml ${githubActionsConfig}
          #   mkdir -p $out/log
          #   echo "Config up to date" > $out/log/build.ansi
          # '';
        };

        packages = rec {
          # inherit githubActionsConfig vaultenv;

          default = upgradeWatcher;

          upgradeWatcher = projectCargo {
            description = "Build binary in release mode";
            cargoCommand = "build --release";
          };

          container = pkgs.dockerTools.buildLayeredImage {
            name = "qezz/upgrade-watcher";
            tag = "v${version}";
            contents = [ upgradeWatcher pkgs.cacert ];

            extraCommands = ''
              mkdir -p etc/upgrade-watcher
            '';

            config.Entrypoint = [
              "${upgradeWatcher}/bin/upgrade-watcher"
              "/etc/upgrade-watcher/upgrade-watcher.toml"
            ];

            # Run as user 1 and group 1, so we don't run as root. There is no
            # /etc/passwd inside this container, so we use user ids instead.
            config.User = "1:1";
          };
        };
      });
}
