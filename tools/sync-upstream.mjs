// Copies the upstream art and translations the apps load into App/Generated/ (gitignored).
// Run after the engine build; scripts/prepare.sh runs both.
//
//   App/Generated/kids/, avatars/          public/kids, public/avatars (loaded by path from the bundle root)
//   App/Generated/badges/                  src/assets/badges (format badges)
//   App/Generated/marks/                   public/toptabl.png, toptabr.png (card ribbons)
//   App/Generated/awards.json              src/data/awards.json
//   App/Generated/Locales/<lang>.json      i18n/<lang>.json (the engine's catalog)
//   App/Generated/Locales/<lang>.lproj/    Localizable.strings from the same catalog (Swift's T())
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const upstream = path.join(root, "reference/harbor");
const out = path.join(root, "App/Generated");
// L10n.swift's list; "en" is the source language and needs no .lproj.
const languages = ["en", "ar", "de", "es", "fr", "hi", "id", "it", "ja", "ko", "pl", "pt", "ru", "tr", "vi", "zh"];

if (!fs.existsSync(path.join(upstream, "src"))) {
  console.error("reference/harbor is empty: run `git submodule update --init`");
  process.exit(1);
}

const copyDir = (from, to) => fs.cpSync(path.join(upstream, from), path.join(out, to), { recursive: true });
const copyFile = (from, to) => {
  fs.mkdirSync(path.dirname(path.join(out, to)), { recursive: true });
  fs.copyFileSync(path.join(upstream, from), path.join(out, to));
};

// Keep the engine bundle (written by engine/build.mjs into App/Generated/Engine) and rebuild the rest.
for (const name of fs.existsSync(out) ? fs.readdirSync(out) : []) {
  if (name !== "Engine") fs.rmSync(path.join(out, name), { recursive: true, force: true });
}

copyDir("public/kids", "kids");
copyDir("public/avatars", "avatars");
copyDir("src/assets/badges", "badges");
copyFile("public/toptabl.png", "marks/toptabl.png");
copyFile("public/toptabr.png", "marks/toptabr.png");
copyFile("src/data/awards.json", "awards.json");

// .strings needs ", \ and newlines escaped.
const esc = (s) => s.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\n").replace(/\r/g, "\\r");
let keys = 0;
for (const lang of languages) {
  const src = path.join(upstream, "i18n", `${lang}.json`);
  if (!fs.existsSync(src)) throw new Error(`missing upstream catalog i18n/${lang}.json`);
  const raw = fs.readFileSync(src, "utf8");
  const catalog = JSON.parse(raw);
  copyFile(`i18n/${lang}.json`, `Locales/${lang}.json`);
  if (lang === "en") continue;
  const lines = Object.entries(catalog)
    .filter(([k, v]) => typeof v === "string" && k !== "")
    .map(([k, v]) => `"${esc(k)}" = "${esc(v)}";`);
  keys = Math.max(keys, lines.length);
  const dir = path.join(out, "Locales", `${lang}.lproj`);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, "Localizable.strings"), lines.join("\n") + "\n");
}

console.log(`App/Generated: art, awards.json, ${languages.length} catalogs (${keys} strings each)`);
