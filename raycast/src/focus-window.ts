import { LaunchProps, showHUD } from "@raycast/api";
import { tell } from "./heed";

export default async function command(props: LaunchProps<{ arguments: { number: string } }>) {
  const number = props.arguments.number;
  if (!/^[1-9]$/.test(number)) {
    await showHUD("Pick a window from 1 to 9");
    return;
  }
  await tell(`focus/${number}`);
}
