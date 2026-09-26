# The EXACT version string of the Zed stable client shipped as the pinned
# installer in .#windows-kit (nix/packages/windows-kit.nix).
#
# Why the full string matters: on connect, the client looks for its remote
# server at `~/.zed_server/zed-remote-server-stable-<version.to_string()>` and
# decides "present" purely by running `<that file> version` (exit 0 = no
# download) — see zed crates/remote/src/transport/wsl.rs. `version.to_string()`
# includes the upstream build metadata (build number + git sha), which a plain
# `pkgs.zed-editor.version` does not. With only the bare version, the first
# offline connect tries to download the server and hangs.
#
# Re-pin in lockstep with the installer (same commit as the version bump in
# windows-kit.nix): install the new kit on Windows, connect once, and copy the
# string from the client log line `starting zed version <this>`. Never guess
# it; it identifies the exact official release artifact.
"1.17.2+stable.349.c8e44cfa7bda9b2e22c8d6934d78969352e7f61a"
