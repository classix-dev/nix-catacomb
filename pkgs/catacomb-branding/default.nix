# Catacomb branding overlay applied on top of upstream
# safe-wallet-monorepo. Returns a patched source tree that
# `pkgs/safe-wallet-web` can consume in place of the raw flake input.
#
# Toggled by `catacomb.branding.enable`; consumers that disable it
# should not call this at all.
#
# What the overlay does:
#   - patches/0001-catacomb-branding.patch
#       replaces the upstream Safe header logo with a `<appName> /
#       <tagline>` wordmark, swaps the bundle's primary version link to
#       `branding.githubRepoLink`, replaces the "unofficial distribution"
#       footer line with `branding.footerLinks`, and adds an SVG-only
#       favicon link in MetaTags.
#   - postPatch
#       drops Michroma + Space Grotesk webfonts, the favicon SVG, and
#       disables the typecheck/eslint enforcement during `next build`
#       (saves ~5 min of single-threaded work per iteration; the static
#       export is the release artefact, not a dev run).
{
  applyPatches,
  src,
  # The wallet's apex favicon. Defaults to the chain logo we ship for
  # the library's default ETC chain; consumers point this at their own
  # SVG for non-Classix Catacomb deploys.
  faviconSvg ? ../../assets/etc-logo.svg,
}:
applyPatches {
  name = "safe-wallet-monorepo-catacomb";
  inherit src;
  patches = [ ./patches/0001-catacomb-branding.patch ];
  postPatch = ''
    cp ${./fonts/Michroma-latin.woff2}     apps/web/public/fonts/Michroma-latin.woff2
    cp ${./fonts/SpaceGrotesk-latin.woff2} apps/web/public/fonts/SpaceGrotesk-latin.woff2
    chmod +w apps/web/public/fonts/fonts.css
    cat >> apps/web/public/fonts/fonts.css <<'EOF'

    @font-face {
      font-family: 'Michroma';
      font-display: swap;
      font-weight: 400;
      src: url('/fonts/Michroma-latin.woff2') format('woff2');
    }

    @font-face {
      font-family: 'Space Grotesk';
      font-display: swap;
      font-weight: 500 700;
      src: url('/fonts/SpaceGrotesk-latin.woff2') format('woff2');
    }
    EOF

    cp ${faviconSvg} apps/web/public/favicons/icon.svg
    cp ${faviconSvg} apps/web/public/favicons/safari-pinned-tab.svg

    chmod +w apps/web/next.config.mjs
    sed -i "s|output: 'export', // static site export|output: 'export', // static site export\n  typescript: { ignoreBuildErrors: true },|" apps/web/next.config.mjs
    sed -i "s|dirs: \['src', 'cypress'\]|dirs: ['src', 'cypress'], ignoreDuringBuilds: true|" apps/web/next.config.mjs
  '';
}
