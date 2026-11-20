{
  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs =
    {
      self,
      flake-utils,
      nixpkgs,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        # The upstream release binaries. nixpkgs ships an older pyrefly, and
        # building this one needs a newer rustc than nixpkgs has. The Linux
        # binaries are statically linked against musl.
        pyrefly =
          let
            version = "1.5.0";
            assets = {
              x86_64-linux = {
                name = "linux-x86_64-musl";
                hash = "sha256-tcAcOf0InLH0W5t1U9Hb/SFkSyPKVyHhbynDJjFlnuE=";
              };
              aarch64-linux = {
                name = "linux-arm64-musl";
                hash = "sha256-DbrsoA0IIYnrVkH7eH/xHsSX8xBlH9DyvETta7QkKcM=";
              };
              x86_64-darwin = {
                name = "macos-x86_64";
                hash = "sha256-wtAPfaN1UZmzwKdYlEwS+WD3P2x4kaDtTmAv442YaMU=";
              };
              aarch64-darwin = {
                name = "macos-arm64";
                hash = "sha256-yGN/2O+Fn6y+cKZHznf6grJjlNSbXzfAJG+yK3tbJl4=";
              };
            };
            asset = assets.${system};
          in
          pkgs.stdenvNoCC.mkDerivation {
            pname = "pyrefly";
            inherit version;
            src = pkgs.fetchurl {
              url = "https://github.com/pyrefly-org/pyrefly/releases/download/${version}/pyrefly-${asset.name}.tar.gz";
              inherit (asset) hash;
            };
            sourceRoot = ".";
            installPhase = "install -Dm755 pyrefly $out/bin/pyrefly";
            meta.mainProgram = "pyrefly";
          };
        # The upstream release binaries, statically linked against musl;
        # nixpkgs ships an older uv. Only the Linux image uses them.
        uv =
          let
            version = "0.13.9";
            assets = {
              x86_64-linux = {
                name = "x86_64-unknown-linux-musl";
                hash = "sha256-WMz18XkrilqI0BvJEOoTGos9tKMZoXrV+tdeCEWj4nE=";
              };
              aarch64-linux = {
                name = "aarch64-unknown-linux-musl";
                hash = "sha256-N/u3xbxmz5nBKqiBlJ0hYYHiAd7ESXcsQynlZIfWEXk=";
              };
            };
            asset = assets.${system};
          in
          pkgs.stdenvNoCC.mkDerivation {
            pname = "uv";
            inherit version;
            src = pkgs.fetchurl {
              url = "https://github.com/astral-sh/uv/releases/download/${version}/uv-${asset.name}.tar.gz";
              inherit (asset) hash;
            };
            installPhase = "install -Dm755 -t $out/bin uv uvx";
            meta.mainProgram = "uv";
          };
        scip-pyrefly = pkgs.writeShellApplication {
          name = "scip-pyrefly";
          runtimeInputs = [ pyrefly ];
          text = builtins.readFile ./scip-pyrefly;
        };
        # Distrust the roots behind the compromised eMudhra intermediate CAs
        # (https://emudhra.we-have-a-problem.com/). The pinned cacert (3.123)
        # already distrusts Comodo AAA Services root for TLS; it is listed as
        # defence in depth. cacert 3.131.1 drops emSign ECC Root CA - G3, so
        # this override fails the build after a nixpkgs bump to it; remove it
        # then.
        dockerTools = pkgs.dockerTools.override {
          cacert = pkgs.cacert.override {
            blacklist = [
              "Comodo AAA Services root"
              "emSign ECC Root CA - G3"
            ];
          };
        };
        # Provides /bin/sh for callers that run commands in the container
        # through a shell. wget and ssl_client are left out: BusyBox does
        # not verify TLS certificates.
        busybox = pkgs.busybox.override {
          extraConfig = ''
            CONFIG_WGET n
            CONFIG_SSL_CLIENT n
          '';
        };
        # nix-ld stands in for the system dynamic loader, so binaries built
        # for other distributions run, such as the Pythons uv downloads and
        # the executables in ninja and cmake wheels.
        loader =
          (if pkgs.stdenv.hostPlatform.isx86_64 then "lib64/" else "lib/")
          + baseNameOf pkgs.stdenv.cc.bintools.dynamicLinker;
      in
      {
        packages = {
          inherit pyrefly scip-pyrefly;
          default = scip-pyrefly;
        }
        // pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
          docker = dockerTools.buildLayeredImage {
            name = "scip-pyrefly";
            tag = "latest";
            contents = [
              scip-pyrefly
              busybox
              dockerTools.caCertificates
              # Not pkgs.git: its Perl tools pull in Mozilla::CA, a separate
              # CA bundle that still trusts emSign ECC Root CA - G3.
              pkgs.gitMinimal
              # Installs the project's dependencies into a virtual
              # environment, with a Python it downloads to match the
              # project's `requires-python`. pyrefly needs no Python.
              uv
            ];
            fakeRootCommands = ''
              mkdir -p /work /tmp "$(dirname /${loader})"
              ln -s ${pkgs.nix-ld}/libexec/nix-ld /${loader}
            '';
            enableFakechroot = true;
            config = {
              Cmd = [ "scip-pyrefly" ];
              WorkingDir = "/work";
              Env = [
                "HOME=/tmp"
                # The Pythons uv downloads look for /etc/ssl/cert.pem.
                "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
                "NIX_LD=${pkgs.stdenv.cc.bintools.dynamicLinker}"
                "NIX_LD_LIBRARY_PATH=${
                  pkgs.lib.makeLibraryPath [
                    pkgs.stdenv.cc.cc
                    pkgs.zlib
                  ]
                }"
              ];
              Labels = {
                "org.opencontainers.image.source" = "https://github.com/sourcegraph/scip-pyrefly";
              };
            };
          };
        };

        checks = {
          shellcheck = pkgs.runCommand "check-shellcheck" { } ''
            ${pkgs.shellcheck}/bin/shellcheck ${./scip-pyrefly}
            touch $out
          '';
          formatting = pkgs.runCommand "check-formatting" { } ''
            ${pkgs.nixfmt}/bin/nixfmt --check ${./flake.nix}
            ${pkgs.shfmt}/bin/shfmt -i 4 -ci -d ${./scip-pyrefly}
            touch $out
          '';
          renovate = pkgs.runCommand "check-renovate" { } ''
            LOG_LEVEL=warn ${pkgs.renovate}/bin/renovate-config-validator \
              ${./.github/renovate.json}
            touch $out
          '';
        };

        devShells.default = pkgs.mkShellNoCC {
          buildInputs = with pkgs; [
            nixfmt
            pyrefly
            shellcheck
            shfmt
          ];
        };
      }
    );
}
