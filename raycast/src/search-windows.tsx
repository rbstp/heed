import { Action, ActionPanel, Icon, List, getApplications, Keyboard } from "@raycast/api";
import { useExec } from "@raycast/utils";
import { useEffect, useMemo, useState } from "react";
import { bundleID, tell } from "./heed";

/// One entry of `Heed --windows`, in the order the numbered shortcuts count.
type HeedWindow = {
  number: number;
  app: string;
  bundleID: string | null;
  title: string | null;
  x: number;
  y: number;
  width: number;
  height: number;
  focused: boolean;
};

export default function SearchWindows() {
  const [binary, setBinary] = useState<string>();
  const [icons, setIcons] = useState<Record<string, string>>({});
  const [missing, setMissing] = useState(false);

  useEffect(() => {
    getApplications().then((apps) => {
      const heed = apps.find((app) => app.bundleId === bundleID);
      if (!heed) {
        setMissing(true);
        return;
      }
      setBinary(`${heed.path}/Contents/MacOS/Heed`);
      // An app icon per bundle id, so the list is scannable without reading it.
      setIcons(
        Object.fromEntries(
          apps.filter((app) => app.bundleId).map((app) => [app.bundleId as string, app.path]),
        ),
      );
    });
  }, []);

  const { isLoading, data, error, revalidate } = useExec(binary ?? "", ["--windows"], {
    execute: binary !== undefined,
  });

  const windows = useMemo<HeedWindow[]>(() => {
    if (!data) return [];
    try {
      return JSON.parse(data) as HeedWindow[];
    } catch {
      return [];
    }
  }, [data]);

  return (
    <List
      isLoading={binary === undefined ? !missing : isLoading}
      searchBarPlaceholder="Search windows"
    >
      {missing ? (
        <List.EmptyView
          icon={Icon.Warning}
          title="Heed is not installed"
          description="brew install --cask rbstp/tap/heed"
        />
      ) : error ? (
        <List.EmptyView
          icon={Icon.Warning}
          title="Heed could not list the windows"
          description={error.message}
        />
      ) : (
        windows.map((window) => (
          <List.Item
            key={window.number}
            icon={
              window.bundleID && icons[window.bundleID]
                ? { fileIcon: icons[window.bundleID] }
                : Icon.AppWindow
            }
            title={window.title?.trim() || window.app}
            subtitle={
              window.title?.trim() && window.title.trim() !== window.app ? window.app : undefined
            }
            accessories={[
              ...(window.focused ? [{ icon: Icon.Dot, tooltip: "Has focus" }] : []),
              {
                text: `${window.width} × ${window.height}`,
                tooltip: `at ${window.x}, ${window.y}`,
              },
              { tag: `${window.number}` },
            ]}
            actions={
              <ActionPanel>
                <Action
                  title="Focus Window"
                  icon={Icon.Center}
                  onAction={() => tell(`focus/${window.number}`)}
                />
                <Action.CopyToClipboard title="Copy Title" content={window.title ?? window.app} />
                <Action
                  title="Refresh"
                  icon={Icon.ArrowClockwise}
                  shortcut={Keyboard.Shortcut.Common.Refresh}
                  onAction={revalidate}
                />
              </ActionPanel>
            }
          />
        ))
      )}
    </List>
  );
}
