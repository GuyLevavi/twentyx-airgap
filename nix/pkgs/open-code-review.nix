# alibaba/open-code-review -- an LLM code reviewer over local git diffs.
# Experimental: on trial against the in-house model.
#
# Built from source rather than via the npm package, whose installer fetches
# a release binary at install time -- a network call that cannot happen
# inside the gap.
{
  lib,
  buildGoModule,
  fetchFromGitHub,
  makeWrapper,
}:
buildGoModule (finalAttrs: {
  pname = "open-code-review";
  version = "1.13.3";

  src = fetchFromGitHub {
    owner = "alibaba";
    repo = "open-code-review";
    tag = "v${finalAttrs.version}";
    hash = "sha256-dDKNxjI0pWoJGabUvsGTERYKvKtvEm3UGD/FLPKpfnw=";
  };

  vendorHash = "sha256-LpqnNp6gxHatHH68pM59ESQICDDSVrkZm7AJLVvYTao=";

  # go.mod asks for 1.26.9 and the pinned nixpkgs has 1.26.7. Nix builds with
  # GOTOOLCHAIN=local, so the mismatch is a hard error rather than a download.
  # A patch-level directive carries no language change; bumping nixpkgs to
  # get two patch releases would turn this transfer into a full re-ship.
  postPatch = ''
    substituteInPlace go.mod --replace-fail 'go 1.26.9' 'go 1.26.7'
  '';

  subPackages = [ "cmd/opencodereview" ];

  ldflags = [
    "-s"
    "-w"
    "-X main.Version=v${finalAttrs.version}"
  ];

  # The suite spawns PTYs, browsers and git fixtures; it is upstream's job.
  doCheck = false;

  nativeBuildInputs = [ makeWrapper ];

  # Point it at the same vLLM endpoint pi uses, unless OCR_LLM_* say
  # otherwise. Unconfigured it defaults to the Anthropic protocol and fails
  # with "no valid LLM endpoint configured". vLLM ignores the token when it
  # runs without --api-key, but ocr refuses an empty one.
  # Telemetry is already off unless OCR_ENABLE_TELEMETRY=1.
  postInstall = ''
    wrapProgram $out/bin/opencodereview \
      --run 'export OCR_LLM_URL="''${OCR_LLM_URL:-''${AIRGAP_LLM_BASE_URL:-}}"' \
      --run 'export OCR_LLM_TOKEN="''${OCR_LLM_TOKEN:-''${AIRGAP_LLM_API_KEY:-none}}"' \
      --run 'export OCR_LLM_MODEL="''${OCR_LLM_MODEL:-''${AIRGAP_LLM_MODEL_ID:-}}"' \
      --set-default OCR_LLM_PROTOCOL openai
    ln -s opencodereview $out/bin/ocr
  '';

  meta = {
    description = "AI code review CLI over local git changes";
    homepage = "https://github.com/alibaba/open-code-review";
    license = lib.licenses.asl20;
    mainProgram = "ocr";
  };
})
