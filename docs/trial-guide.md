English | [简体中文](zh/trial-guide.md)

# Trying Tacit

This guide takes about five minutes to read before you install.

## What Tacit does

Tacit records your AI sessions, meetings and conversations, and which apps are active. It updates the Day overview hourly by default. New Claude Code and Codex sessions can read relevant Project context without asking you to explain it again.

## Install on Mac

You'll need an Apple silicon Mac running macOS 14 or later.

1. Download the latest `Tacit-<version>.dmg` from [Releases](https://github.com/JinSooo/tacit/releases). Open it and drag Tacit to Applications.
2. Double-click Tacit in Applications. If macOS says it can't verify the developer, click **Done**. Open **System Settings › Privacy & Security**, scroll down, click **Open Anyway** next to Tacit, and enter your Mac password. You only need to do this on the first launch.
3. Tacit opens its main window. Open the Setup checklist at the top and work through the remaining steps.
   - **Grant system permissions.** Accessibility lets Tacit see which window is active. Microphone access lets it record.
   - **Set up a Summary model.** Tacit uses Claude Code signed in on this Mac by default. If you don't have it, open **Settings › AI models** to choose Codex or enter an API endpoint and key. Click **Test connection**.
   - **Connect your AI tools.** Connect Claude Code and Codex from Settings.

When you close the main window, Tacit stays in the menu bar and keeps recording. Open Tacit from Applications to bring the window back.

## Before you start recording

- **Recording is on by default.** It downloads about 270 MB of speech models on first use. Tacit transcribes recordings that contain your voice and can transcribe others during meetings. Tell people before recording in-person conversations. You can turn it off under **Settings › Sources › Recording**.
- **Summaries use your model allowance.** Calls through Claude Code count toward your Claude usage. An API provider bills API calls. Set a daily usage limit under **Settings › AI models**.
- **Records are encrypted on your Mac.** Tacit sends the text needed for summaries to the model service you choose.
- **Update available** appears at the top of the Timeline when a new version is ready. Quit Tacit from its menu bar icon's right-click menu, then replace the app in Applications with the one from the new DMG. Your records and permissions carry over.

## If something goes wrong

1. Open **Settings › Maintenance › Copy diagnostics**, then click **Preview** and **Copy**. Diagnostics include versions, component status, and error categories. They exclude record contents.
2. Send the diagnostics to the person who invited you to try Tacit, or file a [GitHub issue](https://github.com/JinSooo/tacit/issues). Include what you saw and roughly when it happened.

Keep your data folder, key backup, and screenshots with private content to yourself. See [troubleshooting](troubleshooting.md) for common issues.

## Uninstall

Run this in Terminal. The script asks whether to delete your data as well.

```sh
sh /Applications/Tacit.app/Contents/Resources/uninstall.sh
```
