English | [简体中文](zh/troubleshooting.md)

# Troubleshooting Tacit

When reporting a problem, include what happened, when it happened, and your diagnostics. Open **Settings › Maintenance › Diagnostics** in Tacit, click **Preview and copy…**, review the contents, and click **Copy**. If the app won't open, start with what happened and when.

Keep your data directory, key backup, and links with access tokens private.

## Tacit won't open or macOS blocks it

Drag Tacit from the disk image to Applications and open it from there. If macOS says it can't verify the developer, confirm that you downloaded the installer from the project release page. Then open **System Settings › Privacy & Security**, click **Open Anyway** under Security, and follow the prompts. Include the macOS message and Tacit version in your report. [Apple's instructions for opening the app](https://support.apple.com/en-us/102445)

## The Background service won't start

Check the **Setup checklist** at the top of the Timeline. While the service is starting, it shows **Preparing the background service…**. If preparation fails, it shows the reason along with **Prepare again** and **Open log folder**. Try **Prepare again** first. If it still fails, include the message and your diagnostics in your report, and keep the full logs on your Mac.

## Records or a source are missing

Open **Settings › Sources** and select the missing source. Check whether it's on, what permissions it has, its status, and when it last ran. You can also switch the Timeline to **Detailed** and check whether there are records for that time. Include the source name and its status in your report.

## Summaries aren't updating

1. Check the **Setup checklist** at the top of the Timeline. It opens automatically on first launch and shows what needs attention, such as neither Claude Code nor Codex being installed, an invalid key, or a usage limit. You can click **Test connection** right from the checklist.
2. Open **Settings › AI models**. If an error appears, click **View reason** under the error message (shown only on this Mac) to see the details. Click **Test connection** to verify your model; if you made changes and see **Connection successful. Save to apply.**, click **Save** so they take effect.
3. If you use a proxy on your Mac, Tacit uses the macOS HTTP/HTTPS system proxy automatically. PAC auto-proxy isn't supported yet—switch your proxy app to System Proxy / Global or TUN mode and test again.

When reporting the issue, send the text from **View reason** together with your diagnostics from **Settings › Maintenance › Diagnostics**.

## A recording hasn't been transcribed

Open **Settings › Sources › Recording**. Check microphone access, the selected microphone, and the transcription queue. If the Timeline asks you to confirm your voice, do that first. Include the recording time, whether you were in a meeting, and the queue status in your report.

## Tacit crashes

Open **Console** on macOS, select **Crash Reports** in the sidebar, and find the Tacit `.ips` file by time. Describe what you did just before the crash. If you need to share the report, check it for personal paths and other private details first. [Apple's guide to crash reports](https://support.apple.com/guide/console/cnsl664be99a/mac)
