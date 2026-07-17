# Release checklist

1. Update [VERSION](../VERSION), `extension/manifest.json`, and the MCP server
   version together. `scripts/build-app.sh` refuses to package a mixed version.
2. Run the full test suite:

   ```bash
   swift test
   node --test extension/test/*.test.mjs
   ```

3. Build, notarize, staple, archive, and verify the extracted app:

   ```bash
   LASSO_NOTARIZE=1 LASSO_NOTARY_PROFILE=lasso-notary scripts/build-app.sh
   ```

4. Test the resulting `build/Lasso-<version>-macos.zip` on a clean macOS user
   account: launch, Screen Recording permission, rectangular capture,
   annotation, Claude/Codex MCP registration, and optional Chrome extension.
5. Create the matching `v<version>` GitHub release. Upload the exact archive
   twice: once as `Lasso-<version>-macos.zip` and once under the stable
   `Lasso-macos.zip` alias used by the landing-page download button. Include its
   SHA-256 in the release notes.

Never publish an archive before the build script's extracted-app verification
has passed.
