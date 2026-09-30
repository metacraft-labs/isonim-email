// tools/capture/transforms.ts — which emulation transforms a backend-A
// capture applies, and the version string that enters the cache key.
//
// Two independent axes compose here:
// - the family: gmailWeb, ganga, outlookWeb, imagesOff and wordApprox
//   rewrite the HTML the way that client would; apple, thunderbird and
//   chromium-baseline render it as authored;
// - images (on/off): with images off, the imagesOff transform (empty
//   img sources, alt text kept, no CSS background-image) runs AFTER the
//   family's own transform, so every family has an images-off view of
//   itself. The imagesOff family is that view on a plain engine, and is
//   the same capture under either value of the axis.

import { GMAIL_WEB_TRANSFORM_VERSION, gmailWeb } from "./emulation/gmailWeb.ts";
import { GANGA_TRANSFORM_VERSION, ganga } from "./emulation/ganga.ts";
import {
  OUTLOOK_WEB_TRANSFORM_VERSION,
  outlookWeb,
} from "./emulation/outlookWeb.ts";
import {
  IMAGES_OFF_TRANSFORM_VERSION,
  imagesOff,
} from "./emulation/imagesOff.ts";
import {
  WORD_APPROX_TRANSFORM_VERSION,
  wordApprox,
} from "./emulation/wordApprox.ts";

export interface Transform {
  name: string;
  version: number;
  apply: (html: string, scheme: string) => string;
}

// The registry. Tests may pass their own (a bumped version, say) to
// the functions below; the CLI always uses this one.
export const TRANSFORMS: Record<string, Transform> = {
  gmailWeb: {
    name: "gmailWeb",
    version: GMAIL_WEB_TRANSFORM_VERSION,
    apply: (html) => gmailWeb(html),
  },
  ganga: {
    name: "ganga",
    version: GANGA_TRANSFORM_VERSION,
    apply: (html) => ganga(html),
  },
  outlookWeb: {
    name: "outlookWeb",
    version: OUTLOOK_WEB_TRANSFORM_VERSION,
    apply: (html, scheme) => outlookWeb(html, scheme),
  },
  imagesOff: {
    name: "imagesOff",
    version: IMAGES_OFF_TRANSFORM_VERSION,
    apply: (html) => imagesOff(html),
  },
  wordApprox: {
    name: "wordApprox",
    version: WORD_APPROX_TRANSFORM_VERSION,
    apply: (html) => wordApprox(html),
  },
};

// The transforms one capture applies, in order: the family's own (if
// any), then imagesOff for images=off unless the family already is it.
export function transformChain(
  family: string,
  images: string,
  registry: Record<string, Transform> = TRANSFORMS,
): Transform[] {
  const chain: Transform[] = [];
  if (family in registry) chain.push(registry[family]);
  if (images === "off" && family !== "imagesOff")
    chain.push(registry.imagesOff);
  return chain;
}

// "name@version" joined by "+" in application order; "" when the
// capture is raw. This is the cache key's transform_version.
export function transformVersion(chain: Transform[]): string {
  return chain.map((t) => `${t.name}@${t.version}`).join("+");
}

export function applyChain(
  chain: Transform[],
  html: string,
  scheme: string,
): string {
  return chain.reduce((acc, t) => t.apply(acc, scheme), html);
}
