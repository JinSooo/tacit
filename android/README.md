English | [简体中文](README.zh-CN.md)

# Tacit for Android

Tacit records conversations that contain your voice when you're away from the computer. It transcribes them on the phone and syncs text to the Mac or a standalone Tacit Background service over an end-to-end encrypted connection. Pair with View permission to read the Timeline from all sources on the home screen. You can also enable AI summaries for individual conversations in Settings. Follow local recording laws and tell people before recording.

Tacit keeps temporary audio in encrypted storage on the phone. It writes a transcript to your records only if it recognizes the voice you confirmed as Me in the retained audio for that conversation. The home screen lists the Timeline or local conversations by day. Open an entry to read, copy, or delete it.

On first launch, enable recording and grant microphone access. Recording resumes when you open Tacit again. You can turn it off from the first row in Settings or from the notification. Listen to a sample and confirm your voice once. Download speech models in recording settings or import them from a verified local model directory. Transcription uses SenseVoice on the CPU. Supported Snapdragon 8 Gen 3 phones can use optional QNN acceleration with CPU fallback. For systems such as HyperOS, see **Settings › Background operation** for autostart and battery management.

Tacit stores records in a SQLCipher database and protects the key with Android Keystore. It strips sensitive material before writing records. Recordings and voice files use a random data key wrapped by Android Keystore. While unpaired, the records stay on the phone. If you enable **AI summaries**, Tacit sends transcripts of conversations that aren't Private to the OpenAI-compatible service you configure. The feature is off by default.

Download `Tacit-<version>.apk` from [GitHub Releases](https://github.com/JinSooo/tacit/releases). It requires an arm64 phone running Android 9 or later. Upgrades require the same release signature and package name, `top.jinso.tacit`. See [Build and publish releases](../docs/installation.md#build-and-publish-releases). Licenses for bundled components and models, including `sherpa-onnx`, ONNX Runtime, FunASR, Qualcomm QNN, and Phosphor, are in `app/src/main/assets/licenses/`.

## Connect to a Mac or a server

1. Create an invitation in Tacit Settings on the Mac. View is the default permission. You can switch between Collect and View. The invitation is single-use and expires after 10 minutes.
2. On the phone, open **Settings › Connect to Mac**. Scan the QR code or paste the Invite link. If the phone cannot find the Mac, enter its address or configure a Relay mailbox on the same page.
3. Once connected, the phone syncs its transcripts and any optional conversation summaries. Deletions and corrections sync in both directions. View permission also brings the Background service's Timeline to the phone. The camera permission prompt appears only when you choose to scan.

Audio stays on the phone. If the Mac has a confirmed voiceprint for Me, the phone uses it to recognize your voice. Otherwise it uses the voice you confirmed on the phone. The phone uses the Background service's audio retention setting. **Disconnect** clears pairing details from the phone.

## Build and verify

You'll need Android SDK 35, JDK 17, cached Gradle dependencies, and both sherpa-onnx AARs in `app/libs/`. The app packages the QNN-compatible `arm64-v8a` AAR. The CPU AAR is the upstream dependency used to produce it.

```sh
export JAVA_HOME=/opt/homebrew/opt/openjdk@17
export ANDROID_HOME="$HOME/Library/Android/sdk"
./scripts/verify.sh
```

Verification runs offline when both AARs are present. If either is missing, `scripts/prepare-speech.sh` prepares and verifies the pinned upstream artifacts. That step needs a network connection or a populated artifact cache. The app prepares the speech models separately.
