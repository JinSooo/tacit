import os from "node:os";
import path from "node:path";
import { buddyFiles, buddyTranscript } from "./codebuddy.ts";
import type { SessionAdapter } from "./types.ts";

export const workBuddy: SessionAdapter = {
  ...buddyTranscript,
  id: "workbuddy",
  files({ workbuddyDir }) {
    return buddyFiles(workbuddyDir ?? process.env.RA_WORKBUDDY_DIR ?? path.join(os.homedir(), ".workbuddy"));
  },
};
