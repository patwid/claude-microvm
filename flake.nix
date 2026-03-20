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
              jq
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

                local i=0
                while [ "$i" -lt 50 ]; do
                  [ -S "$sock" ] && break
                  sleep 0.1
                  i=$((i + 1))
                done
                [ -S "$sock" ] || { echo "error: $label virtiofsd socket did not appear"; exit 1; }
              }

              cleanup() {
                # Restore settings.json before stopping virtiofsd
                if [ -f "$WORK/.claude/settings.json.bak" ]; then
                  mv "$WORK/.claude/settings.json.bak" "$WORK/.claude/settings.json"
                fi
                for u in "''${UNITS[@]+"''${UNITS[@]}"}"; do
                  systemctl --user stop "$u" 2>/dev/null || true
                done
                for s in "''${SOCKETS[@]+"''${SOCKETS[@]}"}"; do
                  rm -f "$s"
                done
              }
              trap cleanup EXIT INT TERM

              # --- Patch settings.json on host (restored in cleanup) ---
              _SETTINGS="$WORK/.claude/settings.json"
              if [ -f "$_SETTINGS" ]; then
                cp "$_SETTINGS" "$_SETTINGS.bak"
                jq 'del(.permissions.disableBypassPermissionsMode)' "$_SETTINGS.bak" > "$_SETTINGS"
              fi

              # --- Work share ---
              SOCK="$RUNTIME/claude-vm-virtiofs-$ID.sock"
              UNIT="claude-vm-virtiofsd-$ID"
              start_virtiofsd "$UNIT" "$SOCK" "$WORK" "work"

              # --- Claude home share ---
              if [ -z "''${CLAUDE_HOME:-}" ]; then
                DATA_HOME="''${XDG_DATA_HOME:-$HOME/.local/share}"
                CLAUDE_HOME="$DATA_HOME/claude-microvm"
              fi
              mkdir -p "$CLAUDE_HOME"
              CLAUDE_DIR="$(realpath "$CLAUDE_HOME")"

              CLAUDE_SOCK="$RUNTIME/claude-vm-virtiofs-$ID-claude-home.sock"
              CLAUDE_UNIT="claude-vm-virtiofsd-$ID-claude-home"
              start_virtiofsd "$CLAUDE_UNIT" "$CLAUDE_SOCK" "$CLAUDE_DIR" "claude-home"

              # --- Gradle cache share (9p, read-only via overlay) ---
              GRADLE_HOST="''${GRADLE_USER_HOME:-$HOME/.gradle}/caches"
              mkdir -p "$GRADLE_HOST"
              GRADLE_DIR="$(realpath "$GRADLE_HOST")"

              # Write host env vars for the VM
              write_vm_env() {
                cat > "$CLAUDE_DIR/.microvm-env" <<ENVEOF
DIRENV_ALLOW=''${DIRENV_ALLOW:-0}
ENVEOF
              }
              write_vm_env

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

              # Run QEMU in runtime dir so relative paths (e.g. QMP socket) don't pollute work dir
              cd "$RUNTIME"
              bash <(sed \
                -e "s|/tmp/claude-vm-work|$WORK|g" \
                -e "s|claude-vm-virtiofs-work.sock|$SOCK|g" \
                -e "s|/tmp/claude-vm-home|$CLAUDE_DIR|g" \
                -e "s|claude-vm-virtiofs-claude-home.sock|$CLAUDE_SOCK|g" \
                -e "s|/tmp/claude-vm-gradle-caches|$GRADLE_DIR|g" \
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
                    {
                      tag = "gradle-cache";
                      source = "/tmp/claude-vm-gradle-caches";
                      mountPoint = "/home/claude/.gradle-caches-ro";
                      proto = "9p";
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
                  extraGroups = [ "docker" ];
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
                  jq
                  openssh
                  cacert
                ];

                programs.direnv = {
                  enable = true;
                  nix-direnv.enable = true;
                };

                virtualisation.docker.enable = true;

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

                fileSystems."/home/claude/.gradle/caches" = {
                  device = "overlay";
                  fsType = "overlay";
                  options = [
                    "lowerdir=/home/claude/.gradle-caches-ro"
                    "upperdir=/tmp/gradle-rw/upper"
                    "workdir=/tmp/gradle-rw/work"
                  ];
                  depends = [ "/home/claude/.gradle-caches-ro" ];
                };

                systemd.tmpfiles.rules = [
                  "d /work 0755 claude claude -"
                  "d /home/claude/.gradle-caches-ro 0755 claude claude -"
                  "d /home/claude/.gradle 0755 claude claude -"
                  "d /home/claude/.gradle/caches 0755 claude claude -"
                  "d /tmp/gradle-rw/upper 0755 claude claude -"
                  "d /tmp/gradle-rw/work 0755 claude claude -"
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
