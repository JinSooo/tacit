<!-- source: docs/troubleshooting.md @ bdb16109701a8d8aa49a62a24da21baf326e4462 -->

English | [简体中文](../troubleshooting.md)

# Troubleshooting Tacit

When reporting a problem, include what happened, when it happened, and your diagnostics. Open **Settings › Maintenance › Copy diagnostics** in Tacit. Click **Preview**, review the contents, and click **Copy**. If the app won't open, start with what happened and when.

Keep your data directory, key backup, and links with access tokens private. This includes the Background service status URL opened from Tacit.

## Tacit won't open or macOS blocks it

Drag Tacit from the disk image to Applications and open it from there. If macOS says it can't verify the developer, confirm that you downloaded the installer from the project release page. Then open **System Settings › Privacy & Security**, click **Open Anyway** under Security, and follow the prompts. Include the macOS message and Tacit version in your report. [Apple's instructions for opening the app](https://support.apple.com/en-us/102445)

## The Background service won't start

Check the message at the top of the Timeline. Use **Open log folder** next to the message to find the logs in Finder. Include the Timeline message in your report and keep the full logs on your Mac.

## Records or a source are missing

Open **Settings › Sources** and select the missing source. Check whether it's on, what permissions it has, its status, and when it last ran. You can also switch the Timeline to **Detailed** and check whether there are records for that time. Include the source name and its status in your report.

## Summaries aren't updating

Check the Setup checklist at the top of the Timeline. It shows what needs attention, such as a missing Claude Code installation, an invalid key, or a usage limit. Then open **Settings › Background & connection › Detailed status** and click **Open in browser**. Check the summary section for the last response, run, and model error. You can test the connection under **Settings › AI models**. Include the last summary time and the model error category in your report.

## A recording hasn't been transcribed

Open **Settings › Sources › Recording**. Check microphone access, the selected microphone, and the transcription queue. If the Timeline asks you to confirm your voice, do that first. Include the recording time, whether you were in a meeting, and the queue status in your report.

## Tacit crashes

Open **Console** on macOS, select **Crash Reports** in the sidebar, and find the Tacit `.ips` file by time. Describe what you did just before the crash. If you need to share the report, check it for personal paths and other private details first. [Apple's guide to crash reports](https://support.apple.com/guide/console/cnsl664be99a/mac)
