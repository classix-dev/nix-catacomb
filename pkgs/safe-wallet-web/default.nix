# Static-export build of safe-global/safe-wallet-monorepo's `apps/web`
# workspace. Replaces the upstream container that runs `next build` at
# startup (see README.md "UI status").
#
# `next.config.mjs` already sets `output: 'export'`, so `next build` emits
# a static directory to `apps/web/out/` — we copy that to `$out` and serve
# it via the host nginx (see `hosts/catacomb/ui.nix`).
#
# Per-deploy values (gateway URL, chain id, branding) are baked in at
# build time, so any change requires a rebuild — but cachix substituters
# absorb the cost when nothing changed.
{
  lib,
  stdenv,
  yarn-berry,
  nodejs_20,
  cacert,
  src,
  appName ? "Safe Wallet",
  gatewayUrl ? "https://safe-client.safe.global",
  defaultChainId ? 1,
  isProduction ? true,
}:
let
  version = "1.88.0";

  # Yarn Berry global cache, populated by a fixed-output derivation. The
  # `outputHash` below pins the entire `apps/web` dependency tree — bump
  # it whenever `yarn.lock` changes (Nix will print the expected hash on
  # mismatch).
  yarnCache = stdenv.mkDerivation {
    pname = "safe-wallet-web-yarn-cache";
    inherit version src;

    nativeBuildInputs = [
      yarn-berry
      nodejs_20
      cacert
    ];

    NODE_EXTRA_CA_CERTS = "${cacert}/etc/ssl/certs/ca-bundle.crt";

    buildPhase = ''
      runHook preBuild

      export HOME="$NIX_BUILD_TOP/home"
      mkdir -p "$HOME"
      export YARN_GLOBAL_FOLDER="$out"
      export YARN_ENABLE_TELEMETRY=0
      export YARN_ENABLE_GLOBAL_CACHE=true

      # `--mode=skip-build` populates the cache without running install
      # scripts; the source repo also sets `enableScripts: false`, so this
      # is belt-and-braces.
      yarn install --immutable --mode=skip-build

      runHook postBuild
    '';

    # Cache content already lives at $out via YARN_GLOBAL_FOLDER.
    installPhase = "true";
    dontFixup = true;

    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = "sha256-s4vHYBdPD6t6g0ASeGrmjPi/lRpLAXTTUkdyWBbRhp4=";
  };
in
stdenv.mkDerivation {
  pname = "safe-wallet-web-static";
  inherit version src;

  nativeBuildInputs = [
    yarn-berry
    nodejs_20
  ];

  # Brand name flows through `apps/web/src/config/constants.ts:BRAND_NAME`
  # — set NEXT_PUBLIC_BRAND_NAME and every consumer (page titles, OG
  # tags, in-app references) picks it up.
  NEXT_PUBLIC_BRAND_NAME = appName;
  NEXT_PUBLIC_GATEWAY_URL_PRODUCTION = gatewayUrl;
  NEXT_PUBLIC_DEFAULT_MAINNET_CHAIN_ID = toString defaultChainId;
  NEXT_PUBLIC_IS_PRODUCTION = if isProduction then "true" else "false";
  NEXT_TELEMETRY_DISABLED = "1";

  # The prerender phase peaks past 5 GB of Node heap. Node 20's default
  # cap is ~2 GB → SIGABRT; bump it. 6 GB fits inside a GH-hosted runner
  # (7 GB total) once we've added swap (.github/workflows/build.yml),
  # and is comfortably under the kart's headroom.
  NODE_OPTIONS = "--max-old-space-size=6144";

  postPatch = ''
    # `yarn fetch-chains` makes a network call to seed chain metadata —
    # incompatible with the Nix build sandbox. The app falls back to a
    # runtime fetch from CGW (which is what fetch-chains itself only
    # *speeds up*; see its own header comment). `--no-lint` skips
    # eslint enforcement (release artefact, not a dev run).
    substituteInPlace apps/web/package.json \
      --replace-fail '"build": "yarn fetch-chains && next build"' \
                     '"build": "next build --no-lint"'

    # `next build` reads chain JSON from this path; create an empty
    # placeholder so the app falls back to its runtime CGW fetch.
    mkdir -p apps/web/src/config/__generated__
    echo '[]' > apps/web/src/config/__generated__/chains.json
  '';

  buildPhase = ''
    runHook preBuild

    export HOME="$NIX_BUILD_TOP/home"
    mkdir -p "$HOME"
    export YARN_GLOBAL_FOLDER=${yarnCache}
    export YARN_ENABLE_TELEMETRY=0
    export YARN_ENABLE_GLOBAL_CACHE=true
    # No network in the build sandbox — fail fast if the cache misses.
    export YARN_ENABLE_NETWORK=0

    # `--mode=skip-build` matches how the cache was populated and avoids
    # running per-package build scripts (cypress binary download, sharp
    # native compile etc.) — none of which we need for `next export`.
    yarn install --immutable --immutable-cache --mode=skip-build
    yarn workspace @safe-global/web after-install
    yarn workspace @safe-global/web build

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    cp -r apps/web/out/. $out/

    runHook postInstall
  '';

  meta = with lib; {
    description = "Static export of safe-wallet-monorepo apps/web";
    homepage = "https://github.com/safe-global/safe-wallet-monorepo";
    license = licenses.gpl3Only;
  };
}
