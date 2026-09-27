# The agent skills, vendored into the store. Same source as /etc/nixos
# (home/skills.nix) and pinned to the same revision: opencode discovers
# ~/.config/opencode/skills/<name>/SKILL.md, and in the gap there is no
# marketplace to fetch them from -- an agent without skills loses every
# workflow.
#
# Whole skill directories as read-only store symlinks (packaged defaults, per
# the $HOME rule). Hand-rolled skills in the same directory are untouched; a
# name collision shows up as a .hm-bak at activation. Upstream's
# marketplace.json only lists its shipped set; these siblings are
# Claude/git-hook machinery opencode cannot run, so they are rejected rather
# than shipped.
{ inputs, lib, ... }:
let
  root = "${inputs.matt-skills}/skills";

  reject = [
    "deprecated"
    "in-progress"
    "misc"
  ];

  dirsIn =
    path:
    builtins.attrNames (lib.filterAttrs (_: type: type == "directory") (builtins.readDir path));

  categories = builtins.filter (category: !(builtins.elem category reject)) (dirsIn root);
in
{
  home.file = builtins.listToAttrs (
    lib.concatMap (
      category:
      map (name: {
        name = ".config/opencode/skills/${name}";
        value.source = "${root}/${category}/${name}";
      }) (dirsIn "${root}/${category}")
    ) categories
  );
}
