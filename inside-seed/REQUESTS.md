# Requests to the outside

The outbound channel. Anything that needs a binary, a closure change or a
WSL system change (package, service, sysctl, /etc) goes here as one line; the
owner carries the file out by hand and answers with a release and, if inside
files must change, a numbered edit in `HANDOVER.md`. Never edit Nix inside.

Format: `- [ ] <date> <who>: <what>, <why>` -- tick it when a release ships it.

