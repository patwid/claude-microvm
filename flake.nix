{
  description = "Claude Code microVM";

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
      nixosConfigurations.claude-vm = lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          microvm.nixosModules.microvm
          (
            { pkgs, ... }:
            {
              nixpkgs.config.allowUnfree = true;

              networking.hostName = "claude-vm";

              virtualisation.docker = {
                enable = true;
                rootless = {
                  enable = true;
                  setSocketVariable = true;
                };
              };

              microvm = {
                hypervisor = "qemu";
                mem = 8192;
                vcpu = 4;

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
                    tag = "claude-credentials";
                    # TODO: custom credentials home dir
                    source = "/home/patwid/.claude-microvm";
                    mountPoint = "/home/claude/.claude";
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

              environment.variables = {
                SSL_CERT_FILE = "/etc/ssl/certs/ca-bundle.crt";
                COLORTERM = "truecolor";
                CLAUDE_CONFIG_DIR = "/home/claude/.claude";
              };

              programs.bash.interactiveShellInit = ''
                git config --global --add safe.directory /work 2>/dev/null || true
                cd /work 2>/dev/null || true
                claude --dangerously-skip-permissions; sudo poweroff
              '';

              systemd.tmpfiles.rules = [
                "d /work 0755 claude claude -"
                "d /home/claude/.claude 0700 claude claude -"
              ];

              documentation.enable = false;

              system.stateVersion = "25.05";
            }
          )
        ];
      };

      overlays.default = final: prev: {
        claude-vm =
          let
            runner = self.nixosConfigurations.claude-vm.config.microvm.runner.qemu;
          in
          final.writeShellApplication {
            name = "claude-run";
            runtimeInputs = with final; [
              systemd
              virtiofsd
            ];

            text = ''
              set -euo pipefail
              WORK="$(realpath "''${WORK_DIR:-$(pwd)}")"
              RUNTIME="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
              ID=$(echo -n "$WORK" | sha256sum | cut -c1-8)

              SOCK="$RUNTIME/claude-vm-virtiofs-$ID.sock"
              UNIT="claude-vm-virtiofsd-$ID"
              STATE="$RUNTIME/claude-vm-virtiofsd-$ID.workdir"

              CREDS_SOCK="$RUNTIME/claude-vm-creds-virtiofs-$ID.sock"
              CREDS_UNIT="claude-vm-creds-virtiofsd-$ID"
              CREDS_STATE="$RUNTIME/claude-vm-creds-virtiofsd-$ID.dir"
              CREDS_DIR="$HOME/.claude-microvm"

              # Common virtiofsd flags (unprivileged user namespace, UID/GID mapping)
              # virtiofsd runs unprivileged in a user namespace (--sandbox=namespace).
              # --uid-map / --gid-map: map host user to namespace root (single-entry, no /etc/subuid needed)
              # --translate-uid / --translate-gid: map guest uid/gid 1000 to namespace uid/gid 0 (= host user)
              VIRTIOFSD_COMMON=(
                --sandbox=namespace
                --uid-map ":0:$(id -u):1:"
                --gid-map ":0:$(id -g):1:"
                --translate-uid "map:1000:0:1"
                --translate-gid "map:1000:0:1"
                --socket-group="$(id -gn)"
                --xattr
              )

              # --- Work virtiofsd ---
              NEED_START_WORK=1
              if systemctl --user is-active "$UNIT" &>/dev/null; then
                if [ -f "$STATE" ] && [ "$(cat "$STATE")" = "$WORK" ] && [ -S "$SOCK" ]; then
                  NEED_START_WORK=0
                else
                  systemctl --user stop "$UNIT" 2>/dev/null || true
                fi
              fi

              if [ "$NEED_START_WORK" = "1" ]; then
                rm -f "$SOCK"
                systemd-run --user --unit="$UNIT" --collect \
                  -- virtiofsd \
                    --socket-path="$SOCK" \
                    --shared-dir="$WORK" \
                    "''${VIRTIOFSD_COMMON[@]}"
                echo "$WORK" > "$STATE"
              fi

              # --- Credentials virtiofsd ---
              NEED_START_CREDS=1
              if systemctl --user is-active "$CREDS_UNIT" &>/dev/null; then
                if [ -f "$CREDS_STATE" ] && [ "$(cat "$CREDS_STATE")" = "$CREDS_DIR" ] && [ -S "$CREDS_SOCK" ]; then
                  NEED_START_CREDS=0
                else
                  systemctl --user stop "$CREDS_UNIT" 2>/dev/null || true
                fi
              fi

              if [ "$NEED_START_CREDS" = "1" ]; then
                rm -f "$CREDS_SOCK"
                mkdir -p "$CREDS_DIR"
                systemd-run --user --unit="$CREDS_UNIT" --collect \
                  -- virtiofsd \
                    --socket-path="$CREDS_SOCK" \
                    --shared-dir="$CREDS_DIR" \
                    "''${VIRTIOFSD_COMMON[@]}"
                echo "$CREDS_DIR" > "$CREDS_STATE"
              fi

              # Wait for both sockets
              for sock in "$SOCK" "$CREDS_SOCK"; do
                for _ in $(seq 1 50); do
                  [ -S "$sock" ] && break
                  sleep 0.1
                done
                [ -S "$sock" ] || { echo "error: virtiofsd socket $sock did not appear"; exit 1; }
              done

              # Run QEMU with corrected paths
              bash <(sed \
                -e "s|/tmp/claude-vm-work|$WORK|g" \
                -e "s|claude-vm-virtiofs-work.sock|$SOCK|g" \
                -e "s|claude-vm-virtiofs-claude-credentials.sock|$CREDS_SOCK|g" \
                ${lib.getExe runner})
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
        packages = {
          default = pkgs.claude-vm;
          inherit (pkgs) claude-vm;
        };

        formatter = pkgs.nixfmt;
      }
    );
}
