# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

claude-microvm runs Claude Code inside an isolated NixOS microVM (QEMU+KVM) using [microvm.nix](https://github.com/microvm-nix/microvm.nix). The host project directory is mounted read-write at `/work` via virtiofs. Claude Code starts on boot; exiting it powers off the VM. No root required.

## Build & Run Commands

```sh
make vm          # Build the VM image (nix build --impure .#claude-vm)
make vm.run      # Build and run with current directory mounted at /work
WORK_DIR=/path/to/project make vm.run  # Mount a specific directory
```

The `--impure` flag is required because `NIXPKGS_ALLOW_UNFREE=1` must be read from the environment.

## Architecture

The entire project is a single Nix flake (`flake.nix`) — no application source code, just declarative NixOS configuration. There are no tests or linters.

### Flake structure

- **NixOS configuration** (`nixosConfigurations.claude-vm`): Defines the VM's OS — user account (`claude`, uid 1000), packages (claude-code, git, openssh, cacert), auto-login, shell init, and sudoers (passwordless `poweroff` only).
- **Package output** (`packages.x86_64-linux.claude-vm`): A `writeShellApplication "claude-run"` wrapper that manages virtiofsd and launches QEMU.

### Runtime flow

1. `claude-run` resolves `WORK_DIR`, generates a unique UUID for this run.
2. Starts two `virtiofsd` systemd user services (work share + claude-home share) with UID/GID mapping so VM files are owned by the host user.
3. Patches and executes the microvm.nix-generated QEMU runner script, substituting the real work directory and socket path.
4. VM boots → auto-login as `claude` → bash init runs `claude --dangerously-skip-permissions` → on exit, `sudo poweroff`.

### Key design decisions

- **virtiofsd runs unprivileged** in a user namespace with single-entry UID/GID maps — no `/etc/subuid` needed.
- **Multiple VMs can run in parallel** — each `WORK_DIR` gets its own virtiofsd instance and socket.
- **Nix store is shared read-only** (9p) with a writable overlay at `/nix/.rw-store`.
- **Network**: QEMU user-mode NAT (outbound internet, no host port binding by default). Port forwarding is configured via `microvm.qemu.extraArgs` in `flake.nix`.

### Inputs

- `nixpkgs` (nixos-unstable) — provides all packages including `claude-code`
- `microvm.nix` — provides the microVM NixOS module and QEMU runner generation
