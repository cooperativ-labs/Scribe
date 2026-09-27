import { readFileSync } from 'node:fs';

// The Scribe logo mark, on a transparent background, shipped beside the server
// as assets/icon.png in every package. Clients show it for the MCP server
// (serverInfo.icons), browsers for the consent page, and connector UIs that
// look up a domain's favicon for the relay. Absent from a checkout without
// assets, which only drops the icon.
export const ICON_PATH = '/icon.png';
export const WEBSITE_URL = 'https://scribe.ovld.ai';
let icon;
export function iconPNG() {
  if (icon === undefined) {
    try { icon = readFileSync(new URL('../assets/icon.png', import.meta.url)); } catch { icon = null; }
  }
  return icon;
}

// An HTTP server names its own copy, so the icon is fetched once and cached; stdio
// has no address, so it inlines the image (the MCP spec allows data: URIs).
export function mcpIcons(origin) {
  const png = iconPNG();
  if (!png) return undefined;
  const src = origin ? new URL(ICON_PATH, origin).href : `data:image/png;base64,${png.toString('base64')}`;
  return [{ src, mimeType: 'image/png', sizes: ['128x128'] }];
}
