# AlmRecorder release checklist

The canonical release path is `Scripts/package_dmg.sh`. `package_app.sh` delegates to it so the
two entry points cannot drift.

## 1. Freeze a reproducible source revision

- Update both version fields in `AlmRecorder/Info.plist`.
- Commit every intended source, public synthetic test, prebuilt native runtime, and submodule
  revision. All submodules must be clean and match the gitlink recorded by the parent repository.
- Publish from a privacy-clean history. `Scripts/check_repository_privacy.sh --history` must pass
  against the exact branch/repository that will become public. If a private archive has ever held
  recordings, transcripts, identity labels, or private evaluation source, create a clean public
  history instead of pushing the archive's existing objects.
- Run `Scripts/check_release_readiness.sh` from a clean checkout.

## 2. Verify code and real workflows

Rebuild both bundled native runtimes from clean temporary build trees:

```bash
./Scripts/package_llama.sh
./Scripts/package_whisper.sh
```

Run the deterministic suites:

```bash
swift test --jobs 2
python3 -m unittest discover -s DeveloperTests/VibeVoiceHelperTests -v
swift build -c release --jobs 2
```

Run the public, opt-in no-mock three-stage proof with an owned or synthetic WAV and a disposable
home containing links or copies of the already installed models (the test never downloads):

```bash
ALMREC_PRODUCTION_CHAIN_AUDIO=/absolute/path/to/test.wav \
ALMREC_PRODUCTION_CHAIN_ISOLATED_HOME=1 \
ALMREC_PRODUCTION_CHAIN_HOME=/private/tmp/almrec-release-home \
HOME=/private/tmp/almrec-release-home \
CFFIXED_USER_HOME=/private/tmp/almrec-release-home \
swift test --filter ProductionThreeStageLiveTests
```

A resource-admission refusal is a failed live proof, not a successful skip. Free memory and swap
and rerun rather than weakening the production watchdog safeguards.

Then use owned/synthetic audio on a clean macOS user account and verify:

- microphone permission, record/stop, import, and Voice Memos access;
- an explicit model install, cancellation, retry, deletion, and re-download;
- VibeVoice foreground transcription with fused speaker turns;
- the complete VibeVoice → Whisper Large v3 → Gemma audio nightly pass, including checkpoint
  recovery and the low-memory waiting state;
- transcript review/undo, export, semantic search, and global speaker reconciliation;
- realtime dictation, Accessibility permission, secure-field refusal, and target-app insertion;
- MCP disabled by default, enable/disable behavior, Unix-socket permissions, and per-recording/tag
  privacy exclusions;
- offline operation after all selected models and the VibeVoice runtime are installed.

Never use a real user library as a committed fixture. Store local benchmark artifacts outside every
git worktree.

## 3. Choose and build one explicit release channel

### Community channel (no Apple developer account)

The community artifact has an ad-hoc code signature so macOS can verify the bundle is internally
consistent, but it has no Apple-issued identity and is not notarized. Build it with:

```bash
ALMREC_RELEASE_CHANNEL=community ./Scripts/package_dmg.sh
```

The result is `dist/AlmRecorder-<version>-community.dmg` with a matching `.sha256` sidecar. The DMG
includes first-launch instructions, and the script verifies the checksum before returning. Upload
both files. The release notes must state prominently that macOS requires explicit approval on first
launch.

### Developer ID channel (optional)

Create a Developer ID Application certificate in the login keychain. Store App Store Connect API
credentials or an app-specific password in a `notarytool` keychain profile, for example:

```bash
xcrun notarytool store-credentials almrecorder-notary
```

Build, sign, notarize, staple, and assess the DMG:

```bash
ALMREC_SIGNING_IDENTITY="Developer ID Application: YOUR LEGAL NAME (TEAMID)" \
ALMREC_NOTARY_PROFILE="almrecorder-notary" \
ALMREC_RELEASE_CHANNEL=developer-id \
./Scripts/package_dmg.sh
```

The Developer ID channel fails closed if either publication credential is absent. For a local
assembly test that is never uploaded:

```bash
ALMREC_ALLOW_ADHOC=1 ./Scripts/package_dmg.sh
```

This produces a `-local.dmg`; never upload that artifact. Only the explicitly named `community`
channel may publish an ad-hoc-signed app.

## 4. Test the exact artifact

- Mount the exact DMG, drag the app to `/Applications`, and test it after downloading it through the
  same public path users will use so the quarantine behavior is preserved.
- For the community channel, first try Control-click/right-click → Open. If still blocked, try a
  normal launch, then use System Settings → Privacy & Security → Open Anyway. Confirm no Terminal
  command or system-wide Gatekeeper change is needed.
- For the Developer ID channel, confirm a normal launch requires no unidentified-developer
  workaround and that notarization/stapling validation passed.
- Run the channel-aware gate before upload:

  ```bash
  ALMREC_RELEASE_CHANNEL=community \
  ./Scripts/check_release_readiness.sh build/AlmRecorder.app
  ```

- Confirm the GitHub release tag, DMG filename, app version, build number, release notes, and
  `.sha256` sidecar refer to the same artifact. Download both assets and run
  `shasum -a 256 -c AlmRecorder-<version>-community.dmg.sha256` before publishing the release.
- Repeat the short synthetic transcription and three-stage quality smoke test from the installed
  application, not from `.build/debug`.
