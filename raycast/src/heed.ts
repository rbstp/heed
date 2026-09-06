import { closeMainWindow, getApplications, open, showHUD } from "@raycast/api";

const bundleID = "io.github.rbstp.heed";

/// Ask the running Heed for something. The vocabulary is Heed's own: `focus/next`, `toggle`.
///
/// One way only. Heed answers nothing back, so `hud` says what was asked for, never what came of
/// it. A URL to a Heed that is not running launches it, and its first answer can be to do nothing
/// while it works out where focus was.
export async function tell(command: string, hud?: string) {
  try {
    if (!(await installed())) {
      await showHUD("Heed is not installed");
      return;
    }

    // Before the URL, or Raycast's own window is what the pointer and the focus ring see.
    await closeMainWindow();
    await open(`heed://${command}`);
    if (hud) {
      await showHUD(hud);
    }
  } catch (error) {
    await showHUD(`Could not reach Heed: ${error instanceof Error ? error.message : error}`);
  }
}

async function installed(): Promise<boolean> {
  const apps = await getApplications();
  return apps.some((app) => app.bundleId === bundleID);
}
