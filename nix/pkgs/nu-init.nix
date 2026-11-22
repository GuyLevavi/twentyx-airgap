# atuin's and starship's nu init, shared by the pod (nix/modules/shell.nix)
# and the WSL system (nix/wsl/packages.nix).
#
# atuin's nu hooks are background jobs, which starship's jobs module counts
# as yours (✦). Label atuin's and leave them out of the count; the greps fail
# the build if either upstream init stops matching.
{
  lib,
  runCommand,
  writableTmpDirAsHomeHook,
  atuin,
  starship,
}:
{
  atuin = runCommand "atuin-nushell-config.nu" {
    nativeBuildInputs = [ writableTmpDirAsHomeHook ];
  } ''
    ${lib.getExe atuin} init nu \
      | sed 's/job spawn {/job spawn --description atuin {/' >$out
    grep -q 'job spawn --description atuin' $out
  '';
  starship = runCommand "starship-nushell-config.nu" { } ''
    ${lib.getExe starship} init nu \
      | sed 's/(job list | length)/(job list | where description? != "atuin" | length)/' >$out
    grep -q 'description? != "atuin"' $out
  '';
}
