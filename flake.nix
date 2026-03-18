{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    microvm.url = "github:microvm-nix/microvm.nix";
    microvm.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      microvm,
    }:
    let
      inherit (nixpkgs) lib;
      eachDefaultSystem =
        f:
        lib.systems.flakeExposed
        |> map (s: lib.mapAttrs (_: v: { ${s} = v; }) (f s))
        |> lib.foldAttrs lib.mergeAttrs { };
    in
    {
      overlays.default = final: prev: {
        claude-vm =
          let
            inherit (final.stdenv.hostPlatform) system;
            inherit (self.nixosConfigurations.${system}.config.microvm) declaredRunner;
          in
          final.writeShellApplication {
            name = "claude-run";
            runtimeInputs = with final; [
              systemd
              virtiofsd
              declaredRunner
            ];

            text = ''
              set -euo pipefail

              WORK="$(realpath "''${WORK_DIR:-$(pwd)}")"
              RUNTIME="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
              ID="$(cat /proc/sys/kernel/random/uuid)"

              # --- virtiofsd helper ---
              # Starts a virtiofsd instance as a systemd user service.
              # virtiofsd runs unprivileged in a user namespace (--sandbox=namespace).
              # --uid-map / --gid-map: map host user to namespace root (single-entry, no /etc/subuid needed)
              # --translate-uid / --translate-gid: map guest uid/gid 1000 to namespace uid/gid 0 (= host user)
              UNITS=()
              SOCKETS=()
              start_virtiofsd() {
                local unit="$1" sock="$2" shared_dir="$3" label="$4"
                UNITS+=("$unit")
                SOCKETS+=("$sock")

                rm -f "$sock"

                systemd-run --user --unit="$unit" --collect \
                  -- virtiofsd \
                    --socket-path="$sock" \
                    --shared-dir="$shared_dir" \
                    --sandbox=namespace \
                    --uid-map ":0:$(id -u):1:" \
                    --gid-map ":0:$(id -g):1:" \
                    --translate-uid "map:1000:0:1" \
                    --translate-gid "map:1000:0:1" \
                    --socket-group="$(id -gn)" \
                    --xattr

                for _ in $(seq 1 50); do
                  [ -S "$sock" ] && break
                  sleep 0.1
                done
                [ -S "$sock" ] || { echo "error: $label virtiofsd socket did not appear"; exit 1; }
              }

              cleanup() {
                for u in "''${UNITS[@]:-}"; do
                  [ -n "$u" ] && systemctl --user stop "$u" 2>/dev/null || true
                done
                for s in "''${SOCKETS[@]:-}"; do
                  [ -n "$s" ] && rm -f "$s"
                done
              }
              trap cleanup EXIT INT TERM

              # --- Work share ---
              SOCK="$RUNTIME/claude-vm-virtiofs-$ID.sock"
              UNIT="claude-vm-virtiofsd-$ID"
              start_virtiofsd "$UNIT" "$SOCK" "$WORK" "work"

              # --- Claude home share ---
              if [ -z "''${CLAUDE_HOME:-}" ]; then
                DATA_HOME="''${XDG_DATA_HOME:-$HOME/.local/share}"
                WORK_HASH="$(echo -n "$WORK" | sha256sum | cut -c1-12)"
                CLAUDE_HOME="$DATA_HOME/claude-microvm/$WORK_HASH"
              fi
              CLAUDE_DIR="$(realpath "$CLAUDE_HOME" 2>/dev/null || echo "$CLAUDE_HOME")"
              if [ ! -d "$CLAUDE_DIR" ]; then
                mkdir -p "$CLAUDE_DIR"
              fi

              CLAUDE_SOCK="$RUNTIME/claude-vm-virtiofs-$ID-claude-home.sock"
              CLAUDE_UNIT="claude-vm-virtiofsd-$ID-claude-home"
              start_virtiofsd "$CLAUDE_UNIT" "$CLAUDE_SOCK" "$CLAUDE_DIR" "claude-home"

              # Write host env vars for the VM
              echo "DIRENV_ALLOW=''${DIRENV_ALLOW:-0}" > "$CLAUDE_DIR/.microvm-env"

              # Pre-cache dev shell environment on host (fast) so the VM doesn't have to evaluate nix
              if [ "''${DIRENV_ALLOW:-0}" = "1" ] && [ -f "$WORK/flake.nix" ]; then
                _DEVSHELL_CACHE="$CLAUDE_DIR/.microvm-devshell"
                _CURRENT_HASH="$(cat "$WORK/flake.nix" "$WORK/flake.lock" 2>/dev/null | sha256sum | cut -c1-16)"
                _CACHED_HASH=""
                [ -f "$_DEVSHELL_CACHE.hash" ] && _CACHED_HASH="$(cat "$_DEVSHELL_CACHE.hash")"
                if [ "$_CURRENT_HASH" != "$_CACHED_HASH" ] || [ ! -s "$_DEVSHELL_CACHE" ]; then
                  echo "caching dev shell environment..."
                  if nix print-dev-env --no-update-lock-file "$WORK" > "$_DEVSHELL_CACHE.tmp" 2>/dev/null; then
                    mv "$_DEVSHELL_CACHE.tmp" "$_DEVSHELL_CACHE"
                    echo "$_CURRENT_HASH" > "$_DEVSHELL_CACHE.hash"
                  else
                    rm -f "$_DEVSHELL_CACHE.tmp"
                  fi
                fi
              fi

              # Run QEMU with corrected paths
              bash <(sed \
                -e "s|/tmp/claude-vm-work|$WORK|g" \
                -e "s|claude-vm-virtiofs-work.sock|$SOCK|g" \
                -e "s|/tmp/claude-vm-home|$CLAUDE_DIR|g" \
                -e "s|claude-vm-virtiofs-claude-home.sock|$CLAUDE_SOCK|g" \
                "$(command -v microvm-run)")
            '';
          };
      };
    }
    // eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = builtins.attrValues self.overlays;
        };
      in
      {
        nixosConfigurations = lib.nixosSystem {
          inherit system;
          modules = [
            microvm.nixosModules.microvm
            (
              { config, pkgs, ... }:
              {
                nixpkgs.config.allowUnfree = true;

                networking.hostName = "claude-vm";

                microvm = {
                  hypervisor = "qemu";
                  mem = 16384;
                  vcpu = 8;
                  balloon = true;

                  writableStoreOverlay = "/nix/.rw-store";

                  shares = [
                    {
                      tag = "ro-store";
                      source = "/nix/store";
                      mountPoint = "/nix/.ro-store";
                      proto = "9p";
                    }
                    {
                      tag = "work";
                      source = "/tmp/claude-vm-work";
                      mountPoint = "/work";
                      proto = "virtiofs";
                    }
                    {
                      tag = "claude-home";
                      source = "/tmp/claude-vm-home";
                      mountPoint = "/home/claude";
                      proto = "virtiofs";
                    }
                  ];

                  qemu.extraArgs = [
                    "-netdev"
                    "user,id=usernet"
                    "-device"
                    "virtio-net-device,netdev=usernet"
                  ];
                };

                users.groups.claude.gid = 1000;
                users.users.claude = {
                  isNormalUser = true;
                  uid = 1000;
                  group = "claude";
                  home = "/home/claude";
                  shell = pkgs.bash;
                };

                services.getty.autologinUser = "claude";

                users.motd = "";

                programs.bash.logout = ''
                  sudo poweroff
                '';

                security.sudo = {
                  enable = true;
                  extraRules = [
                    {
                      users = [ "claude" ];
                      commands = [
                        {
                          command = "/run/current-system/sw/bin/poweroff";
                          options = [ "NOPASSWD" ];
                        }
                      ];
                    }
                  ];
                };

                environment.systemPackages = with pkgs; [
                  claude-code
                  git
                  openssh
                  cacert
                ];

                programs.direnv = {
                  enable = true;
                  nix-direnv.enable = true;
                };

                virtualisation.docker = {
                  enable = true;
                  rootless = {
                    enable = true;
                    setSocketVariable = true;
                  };
                };

                environment.variables = {
                  SSL_CERT_FILE = "/etc/ssl/certs/ca-bundle.crt";
                  COLORTERM = "truecolor";
                  DISABLE_AUTOUPDATER = "1";
                };

                programs.bash.interactiveShellInit = ''
                  git config --global --add safe.directory /work 2>/dev/null || true

                  cd /work 2>/dev/null || true
                  [ -f ~/.microvm-env ] && source ~/.microvm-env
                  if [ "''${DIRENV_ALLOW:-0}" = "1" ]; then
                    if [ -f ~/.microvm-devshell ] && [ -s ~/.microvm-devshell ]; then
                      echo "loading dev environment..."
                      _ORIG_PATH="$PATH"
                      source ~/.microvm-devshell 2>/dev/null || true
                      export PATH="$PATH:$_ORIG_PATH"
                      unset _ORIG_PATH
                    else
                      echo "running direnv allow ..."
                      direnv allow 2>/dev/null || true
                      echo "running direnv export ..."
                      eval "$(direnv export bash 2>/dev/null)" || true
                    fi
                  fi
                  echo "starting claude ..."
                  claude --dangerously-skip-permissions; sudo poweroff
                '';

                systemd.tmpfiles.rules = [
                  "d /work 0755 claude claude -"
                ];

                nix.settings.experimental-features = [
                  "nix-command"
                  "flakes"
                  "pipe-operators"
                ];
                nix.gc = {
                  automatic = true;
                  dates = "daily";
                  options = "--delete-older-than 7d";
                };

                documentation.enable = false;

                system.stateVersion = lib.trivial.release;
              }
            )
          ];
        };

        packages = {
          default = pkgs.claude-vm;
          inherit (pkgs) claude-vm;
        };

        formatter = pkgs.nixfmt;
      }
    );
}
