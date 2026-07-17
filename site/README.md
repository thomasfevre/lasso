# Lasso landing page

This directory is a dependency-free static site. GitHub Pages deploys it through
`.github/workflows/deploy-pages.yml` after a push to `main`.

## Preview locally

```bash
python3 -m http.server 4174 --directory site
```

Then open <http://127.0.0.1:4174>.

## Release handoff

All download buttons point to the stable `Lasso-macos.zip` asset on the latest
GitHub release. Publish that exact asset name with every release; the landing
does not need an edit for a new version.

For anonymous visitors, the GitHub repository and release must be public, or
the asset URL must be replaced with an equivalent public file host before
deploying this page.
