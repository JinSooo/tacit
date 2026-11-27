English | [简体中文](zh/trial-guide.md)

# Trying Tacit

This guide takes about five minutes to read before you install.

## What Tacit does

Tacit records your AI sessions, meetings and conversations, and which apps are active. It updates the Day overview hourly by default. New Claude Code and Codex sessions can read relevant Project context without asking you to explain it again.

## Install on Mac

You'll need an Apple silicon Mac running macOS 14 or later.

1. Download the latest `Tacit-<version>.dmg` from [Releases](https://github.com/JinSooo/tacit/releases). Open it and drag Tacit to Applications.
2. Double-click Tacit in Applications. If macOS says it can't verify the developer, click **Done**. Open **System Settings › Privacy & Security**, scroll down, click **Open Anyway** next to Tacit, and enter your Mac password. You only need to do this on the first launch.
3. Tacit opens its main window, and the **Setup checklist** at the top opens automatically. While the background service is starting up, it shows **Preparing the background service…**; if preparation fails, it shows the reason and a **Prepare again** button. Work through the remaining steps:
   - **Grant system permissions.** Accessibility lets Tacit see which window is active. Microphone access lets it record. If you use Safari, it may also ask for Full Disk Access for browser history (optional; you can turn off Browser under **Settings › Sources**).
   - **Set up summaries for your records.** Tacit uses Claude Code signed in on this Mac by default. If only Codex is installed, it uses Codex automatically; if neither is installed, the checklist tells you directly. You can click **Test connection** right in the checklist. To switch models or enter an API endpoint and key, open **Settings › AI models**, click **Test connection**, and click **Save** when you see **Connection successful. Save to apply.** Changes take effect only after you save.
   - **Connect your AI tools.** Connect Claude Code and Codex from **Settings › AI tools**.

If you use a proxy on your Mac, Tacit automatically uses the macOS HTTP/HTTPS system proxy, so you don't need to set proxy variables in Terminal. PAC auto-proxy isn't supported yet—switch your proxy app to System Proxy / Global or TUN mode if needed.

When you close the main window, Tacit stays in the menu bar and keeps recording. Open Tacit from Applications to bring the window back.

## Before you start recording

- **Recording is on by default.** It downloads about 270 MB of speech models on first use. Tacit transcribes recordings that contain your voice and can transcribe others during meetings. Tell people before recording in-person conversations. You can turn it off under **Settings › Sources › Recording**.
- **Summaries use your model allowance.** Calls through Claude Code count toward your Claude usage. An API provider bills API calls. Set a daily usage limit under **Settings › AI models**.
- **Records are encrypted on your Mac.** Tacit sends the text needed for summaries to the model service you choose.
- **Update available** appears at the top of the Timeline when a new version is ready. Click Update and Tacit installs it and reopens. On 0.7.4 or earlier, quit Tacit from its menu bar icon's right-click menu, then replace the app in Applications with the one from the new DMG. Your records and permissions carry over.

## If something goes wrong

If summaries fail, first check **View reason** under **Settings › AI models** (shown only on this Mac), and send that text along with your diagnostics.

1. Open **Settings › Maintenance › Diagnostics**, click **Preview and copy…**, review the contents, and click **Copy**. Diagnostics include versions, component status, and error categories. They exclude record contents.
2. Send the diagnostics to the person who invited you to try Tacit, or file a [GitHub issue](https://github.com/JinSooo/tacit/issues). Include what you saw and roughly when it happened.

Keep your data folder, key backup, and screenshots with private content to yourself. See [troubleshooting](troubleshooting.md) for common issues.

## Uninstall

Run this in Terminal. The script asks whether to delete your data as well.

```sh
sh /Applications/Tacit.app/Contents/Resources/uninstall.sh
```
