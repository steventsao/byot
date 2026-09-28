// Writes the rendered pages plus public/ into a folder for offline review:
//   node scripts/render-static.ts <out-dir>
import { cpSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { renderInformation } from "../src/information.ts";
import { renderLanding } from "../src/landing.ts";

const out = process.argv[2] ?? "dist-static";
mkdirSync(out, { recursive: true });
cpSync("public", out, { recursive: true });
const relative = (html: string) => html.replaceAll('="/shots/', '="shots/');
writeFileSync(join(out, "index.html"), relative(renderLanding()));
for (const page of ["privacy", "support"]) writeFileSync(join(out, `${page}.html`), renderInformation(`/${page}`)!);
console.log(out);
