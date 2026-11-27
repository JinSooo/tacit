English | [简体中文](zh/installation.md)

# Installation, the Background service, and releases

Start with the [README](../README.md) if you're new to Tacit. This guide covers what the app sets up after installation and how installers are built and released.

## Inside the app bundle

`Tacit.app` includes everything the Background service needs, including Bun. It runs independently of the source checkout.

| Path | Contents |
| --- | --- |
| `Contents/MacOS/Tacit` | Menu bar app and capture |
| `Contents/MacOS/ra-audio-worker` | On-device transcription process |
| `Contents/Helpers/Tacit` | Background runtime (Bun). The build uses an official signed Bun distribution, renames it, and re-signs it with Tacit's certificate while keeping its entitlements. macOS therefore names Tacit in background item alerts. |
| `Contents/PlugIns/TacitWidget.appex` | Medium and large desktop widgets, signed with the app's certificate |
| `Contents/Resources/runtime/` | A snapshot of the Background service, summary jobs, built-in Sources, and Web view |
| `Contents/Resources/uninstall.sh` | Uninstaller |

## First launch and upgrades

Open Tacit from Applications (`/Applications` or `~/Applications`). If launched from the disk image or from a temporary location assigned by macOS, Tacit asks you to drag it into Applications and quits before registering the Background service.

Each time the app opens from Applications it runs `bun runtime/hub/src/cli.ts setup --app <app-path>` in the background, with output in `logs/setup.log`. See `hub/src/setup.ts`.

- If the app path or build number differs from `app-setup.json`, setup creates the data directory, creates or reads the database key in Keychain, and checks that the database opens. It also updates `collector.json` and moves existing Claude Code and Codex connections to the new path.
- Setup writes three LaunchAgents, `dev.record-anything.hub`, `dev.record-anything.distill`, and `dev.record-anything.collector`. If their definitions change or full setup just ran, it restarts the Background service and the summary process and waits for the service health check.
- The Background service and summary process start with the login shell's `PATH` and add common install locations so they can find the signed-in `codex` and `claude` commands. Stable command paths take priority, so CLI upgrades that only change a symlink target need no setup. If you install a CLI later, reopen Tacit.
- With launch at login turned off, the LaunchAgent files stay in `launch-agents/` in the data directory. Upgrades keep that preference.

The summary process checks for work every 15 minutes. If it exits unexpectedly, launchd restarts it at least 60 seconds after the previous launch. It runs in the background with low I/O priority and a nice value of 10. Logs are in `~/Library/Application Support/record-anything/logs/`. The summary configuration is in `models.json` in the data directory. Without this file, Tacit uses the local Claude CLI sign-in, with Haiku for Live and Sonnet for Hourly roundup and Daily timeline; if only Codex is installed on this Mac (without Claude Code), setup automatically configures Codex instead. Each CLI manages its own credentials.

Background network requests (model calls, speech model downloads, and relay sync) automatically use macOS HTTP/HTTPS system proxy settings, so you don't need to configure a proxy in Terminal. PAC auto-proxy is not supported yet; switch your proxy app to System Proxy / Global or TUN mode if needed.

If the Background service fails before it starts listening, `hub-startup-error.json` records the time, error code, and description in the data directory. A successful start clears the file. `logs/setup.log` rotates at 5 MiB and keeps the two most recent copies.

## Speech models

The first time you enable recording, Tacit uses `cli.ts audio-models` to download about 270 MB of models into `models/` in the data directory. It verifies each file's SHA-256 before moving it into place. See `hub/src/audio-models.ts`. Downloads first try Tacit's own GitHub Release mirror (`models-v1`) and fall back to upstream sources (`sherpa-onnx` on GitHub for the VAD and speaker models; Hugging Face for SenseVoice, and finally the ~1 GB `sherpa-onnx` archive on GitHub if single-file downloads fail). The recording status shows the reason for a failed download. Tacit retries when recording next starts, after a 60-second wait.

## Install from source

`./install.sh` prepares the inference libraries using `scripts/fetch-audio-lib.sh`, builds the Web view, builds and signs the app, installs it in Applications, and runs the same `setup` command. It also opens the menu bar app. Before an upgrade, the script checks the signature and saves the existing bundle, LaunchAgents, and capture configuration in `install-rollback` in the data directory.

If the upgrade or Background service setup fails, the script restores the previous app and LaunchAgents and tries to reload the previously running jobs.

Run `RA_NO_DISTILL=1 ./install.sh` to disable automatic summaries. Tacit keeps this setting when you reopen the app. Run `./install.sh` without the variable to resume automatic summaries.

## Desktop widgets

After opening Tacit from Applications, right-click the desktop, choose **Edit Widgets**, search for Tacit, and add the Tacit Timeline widget. Clicking the widget opens today's Timeline. The app checks today's summaries at startup, on wake, when records change, and every 10 minutes. Changes trigger a widget refresh.

Tacit writes today's Day overview, activity periods, and recent activities to `~/Library/Application Support/record-anything/widget/today.json` for the medium and large widgets. The large widget displays four or five activities. The widget sandbox has read-only access to the directory. At midnight or when the app runs again, Tacit removes the snapshot from the previous day. Uninstalling clears the widget directory even if you keep your records.

To verify widgets on a fresh Mac with System Integrity Protection enabled, generate today's summary after first launch and then add a widget from the gallery. Check that adding and refreshing it works without a prompt to access other apps' data. Compare the content with today's Timeline and verify that clicking the widget opens the correct day and that the previous day's snapshot is cleared.

## Build and publish releases

Mac and Android have separate releases and version numbers. Release whichever platform changed. The Mac installer and the Docker image contain the same Background service and share a version. Cross-platform compatibility depends on the device protocol version `v` in section 6 of the [API contracts](contracts.md) (Chinese). If a protocol change breaks compatibility, give the minimum compatible version for the other platform in the release notes.

Update the relevant version source and run `bun site/build.ts` for each release. The build fills in the versions and download links on both languages' homepages and download pages from these sources:

| Platform | Source |
| --- | --- |
| Mac | `site/src/latest.json` supplies `mac.version` and the `mac.url` release page. Download buttons link straight to `Tacit-<version>.dmg` on that release. `site/src/appcast.json` supplies the in-app update feed `appcast.xml` and must name the same version. |
| Android | `versionName` in `android/app/build.gradle.kts` determines the Android release tag and the direct `Tacit-<version>.apk` download link. The `android` entry in `site/src/latest.json` feeds the phone's update check and must match `versionName`. |
| Docker | `version` in `package.json` determines the Background service image tag and versioned pull command. |

The build fills the download templates in `hero.html` and `download.html` automatically.

### Mac

1. Update the version in `package.json`, `CFBundleShortVersionString` in `collector/build.sh`, and `serverInfo` in `hub/src/agent-cli/mcp.ts` and its test. The consistency test is `scripts/release-version.test.ts`. Leave the `mac` entry in `site/src/latest.json` alone; step 4 changes it. Commit and tag `mac-v<version>`.
2. On a Mac with the signing certificate, the in-app update key `~/.config/tacit/sparkle-ed25519.key`, and [uv](https://docs.astral.sh/uv/) installed, run `scripts/release-dmg.sh`. It requires a clean working tree and the tag on the current commit. It uses `uvx` to run a pinned version of dmgbuild for the disk image layout. It writes `dist/Tacit-<version>.dmg`, its `.sha256` file, and the Sparkle signature `.sparkle`. It verifies the code signature, bundled runtime, and update key from the mounted image.
3. Push the tag and upload both files to the release.

   ```sh
   gh release create mac-v<version> dist/Tacit-<version>.dmg dist/Tacit-<version>.dmg.sha256 --prerelease --title "Tacit v<version> - Mac" --notes-file <notes-file>
   ```

   Pushing `mac-v<version>` triggers `.github/workflows/hub-image.yml` to publish the image to `ghcr.io/jinsooo/tacit-hub:<version>` and `:latest`. Check the workflow result in Actions.
4. Once the installer is on the release, run `bun scripts/publish-mac-update.ts`. It confirms the installer is downloadable and sets the `mac` entry in `site/src/latest.json` and `site/src/appcast.json` to the new version. Commit, then build and deploy the website. See the [site README](../site/README.md).
   Tacit checks `https://tacit.jinso.top/latest.json` daily and shows Update available on the Timeline if the published version is newer. The version row in Settings › General also checks on demand. The request includes no cookies or device details. Failed checks stay quiet. Update hands off to [Sparkle](https://sparkle-project.org), which reads `appcast.xml`, downloads the installer, checks it against the public key in the app, replaces the app, and relaunches it. Tacit 0.7.4 and earlier lack Sparkle and still open the download.

### Android

1. Update `versionName` in `android/app/build.gradle.kts` and increment `versionCode`. Set the `android` entry in `site/src/latest.json` to the same version and the new release tag page. `scripts/release-version.test.ts` checks both. Commit and tag `android-v<version>`.
2. Run `scripts/release-apk.sh` with the release signing key configured, a clean working tree, and the tag on the current commit. It writes `dist/Tacit-<version>.apk` and its `.sha256` file. The APK targets `arm64-v8a`.
3. Push the tag and upload both files to the release.

   ```sh
   gh release create android-v<version> dist/Tacit-<version>.apk dist/Tacit-<version>.apk.sha256 --prerelease --latest=false --title "Tacit v<version> - Android" --notes-file <notes-file>
   ```

   `--latest=false` keeps GitHub from marking Android as the latest release. GitHub's `releases/latest` returns 404 while all releases are prereleases. The README links to the release list. The site links to the individual release tags. Rebuild and deploy it after the APK is available. The phone reads `latest.json` daily and shows Update available at the top of its timeline when a newer build is listed, after any recording problem. The version line at the bottom of Settings also checks on demand. The request includes no cookies or device details.

Use `Tacit v<version> - Mac` or `Tacit v<version> - Android` as the release title. GitHub's Pre-release label indicates preview status.

macOS accessibility, screen recording, and microphone permissions are tied to Tacit's self-signed certificate. Android upgrades likewise require the same release signing key. Back up both offline. The release scripts fail if the signing material is missing. Android debug builds fall back to the default debug key when the release key is unavailable.
