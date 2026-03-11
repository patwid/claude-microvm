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
            inherit (self.nixosConfigurations.${system}.config.microvm) runner;
          in
          final.writeShellApplication {
            name = "claude-run";
            runtimeInputs = with final; [
              systemd
              virtiofsd
              runner.qemu
            ];

            text = ''
              set -euo pipefail

              WORK_DIR="$(realpath "''${WORK_DIR:-$(pwd)}")"
              CONFIG_DIR="$(realpath "''${CONFIG_DIR:-$HOME/.claude-microvm}")"
              RUNTIME="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
              ID=$(echo -n "$WORK_DIR" | sha256sum | cut -c1-8)

              WORK_SOCK="$RUNTIME/claude-vm-work-virtiofs-$ID.sock"
              WORK_UNIT="claude-vm-work-virtiofsd-$ID"
              WORK_STATE="$RUNTIME/claude-vm-work-virtiofsd-$ID.workdir"

              CONFIG_SOCK="$RUNTIME/claude-vm-config-virtiofs-$ID.sock"
              CONFIG_UNIT="claude-vm-config-virtiofsd-$ID"
              CONFIG_STATE="$RUNTIME/claude-vm-config-virtiofsd-$ID.dir"

              # Start (or reuse) a virtiofsd instance for a given directory.
              # Args: $1=unit  $2=socket  $3=state-file  $4=shared-dir
              ensure_virtiofsd() {
                local unit=$1 sock=$2 state=$3 dir=$4
                local need_start=1
                if systemctl --user is-active "$unit" &>/dev/null; then
                  if [ -f "$state" ] && [ "$(cat "$state")" = "$dir" ] && [ -S "$sock" ]; then
                    need_start=0
                  else
                    systemctl --user stop "$unit" 2>/dev/null || true
                  fi
                fi
                if [ "$need_start" = "1" ]; then
                  rm -f "$sock"
                  mkdir -p "$dir"
                  # virtiofsd runs unprivileged in a user namespace (--sandbox=namespace).                                                                                                                                            
                  # --uid-map / --gid-map: map host user to namespace root (single-entry, no /etc/subuid needed)                                                                                                                      
                  # --translate-uid / --translate-gid: map guest uid/gid 1000 to namespace uid/gid 0 (= host user)    
                  systemd-run --user --unit="$unit" --collect \
                    -- virtiofsd \
                      --socket-path="$sock" \
                      --shared-dir="$dir" \
                      --sandbox=namespace \
                      --uid-map ":0:$(id -u):1:" \
                      --gid-map ":0:$(id -g):1:" \
                      --translate-uid "map:1000:0:1" \
                      --translate-gid "map:1000:0:1" \
                      --socket-group="$(id -gn)" \
                      --xattr
                  echo "$dir" > "$state"
                fi
              }

              ensure_virtiofsd "$WORK_UNIT" "$WORK_SOCK" "$WORK_STATE" "$WORK_DIR"
              ensure_virtiofsd "$CONFIG_UNIT" "$CONFIG_SOCK" "$CONFIG_STATE" "$CONFIG_DIR"

              # Wait for both sockets
              for sock in "$WORK_SOCK" "$CONFIG_SOCK"; do
                for _ in $(seq 1 50); do
                  [ -S "$sock" ] && break
                  sleep 0.1
                done
                [ -S "$sock" ] || { echo "error: virtiofsd socket $sock did not appear"; exit 1; }
              done

              # Run QEMU in runtime dir so relative paths (e.g. QMP socket) don't pollute work dir
              cd "$RUNTIME"
              bash <(sed \
                -e "s|/tmp/claude-vm-work|$WORK_DIR|g" \
                -e "s|/tmp/claude-vm-config|$CONFIG_DIR|g" \
                -e "s|claude-vm-virtiofs-work.sock|$WORK_SOCK|g" \
                -e "s|claude-vm-virtiofs-config.sock|$CONFIG_SOCK|g" \
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
                  mem = 16384;
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
                      tag = "config";
                      source = "/tmp/.claude-vm-config";
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

        packages = {
          default = pkgs.claude-vm;
          inherit (pkgs) claude-vm;
        };

        formatter = pkgs.nixfmt;
      }
    );
}
