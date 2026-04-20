# RTV-mod-Localizer

An offline localization builder for [Road to Vostok](https://store.steampowered.com/app/2615690/Road_to_Vostok/) mods.

It reads JSON translation packs, rebuilds the affected mod `.vmz` archives with translated strings, and hands the new `.vmz` files to Road to Vostok on the next launch. It does **not** hook the UI, patch anything at runtime, or ship translations itself — packs are authored by the community, and this mod just builds/deploys them.

Companion tool: [RTV-text-extractor](https://github.com/) — a Python script that scans a `.vmz` and emits a ready-to-fill pack JSON, so translators can skip hand-digging through `.vmz` internals.

**Locale-agnostic.** The builder and the extractor are not Chinese-specific. The published release bundle happens to ship `zh_cn` packs as an example, but the same format, same workflow, and same MCM UI support every locale below. A pack is just `<locale>.json` placed under `Packs/<mod_id>/`:

`ar_ar` (Arabic) · `de_de` (Deutsch) · `es_es` (Español) · `it_it` (Italiano) · `ja_jp` (Japanese) · `ko_kr` (Korean) · `pt_br` (Português) · `ru_ru` (Russian) · `us_us` (English US) · `zh_cn` (Chinese Simplified) · `zh_tw` (Chinese Traditional)

Multiple locales can coexist per mod — the MCM dropdown lists whichever `<locale>.json` files it finds.

---

## Scope and Limitations — Please Read First

Godot mod development is free-form. There is no community-wide convention for where user-facing strings live inside a `.vmz`, which properties they're assigned to, or how they're composed at runtime. As long as that remains true, **no automated localization pipeline can hit 100% coverage across every mod**. `RTV-mod-Localizer` is not an exception.

What this mod is designed to do:

- **Apply packs offline and predictably.** Source is backed up as `<ModName>.vmz.rtvsrc` before anything is written, so a restore path always exists.
- **Resolve strings conservatively.** A literal is translated only when the pack entry's `where` block uniquely matches that occurrence. Ambiguous matches are skipped, not guessed.
- **Make the pack format diffable.** Packs are plain JSON, so re-running the extractor against a new mod version surfaces only the added / removed / reworded strings.

What this mod cannot do:

- It cannot translate strings that aren't in the pack. If the extractor missed a literal or the mod author composed it at runtime, the pack won't have it and the Localizer won't touch it.
- It cannot judge translation quality. Pack contents are taken at face value.
- It cannot replace a shared localization standard. Until mod authors adopt consistent conventions for exposing translatable text, a hand-authored tail of entries per mod will remain necessary.

Treat Localizer + extractor as **a force multiplier for translators**, not a turnkey full-coverage solution.

---

## How It Works

On each game launch the mod:

1. scans `…/Road to Vostok/mods/RTV-mod-Localizer/Packs/` for pack folders
2. matches each pack folder against installed `.vmz` mods by `mod_id`
3. for every mod + locale pair the user has enabled in MCM:
   - unzips the source `.vmz` (preferring the `.vmz.rtvsrc` backup if present)
   - rewrites recognized string literals inside `.gd`, `.tscn`, `.tres`, `.cfg` files using the pack entries
   - rezips into a cached localized `.vmz`
4. backs up the original mod as `<ModName>.vmz.rtvsrc` (once, idempotent)
5. deploys the localized `.vmz` under the original filename
6. asks the user to restart the game so Road to Vostok reloads the updated `.vmz` files

If a pack is later removed or disabled, the mod restores the original `.vmz` from the backup on the next startup.

The Localizer intentionally does **not** rename node ids, resource paths, file paths, or gameplay keys — only recognized display-text properties and MCM strings are eligible for rewrite.

---

## Installation (End User)

1. Install [00ModConfigurationMenu](https://www.nexusmods.com/) (MCM). Required for the settings menu.
2. Drop `RTV-mod-Localizer.vmz` into `…/Road to Vostok/mods/`.
3. Drop the `RTV-mod-Localizer/Packs/` folder (containing one sub-folder per translated mod) into `…/Road to Vostok/mods/` so the final path looks like `…/mods/RTV-mod-Localizer/Packs/<mod_id>/<locale>.json`.
4. Launch the game, open MCM → **RTV-mod-Localizer**, enable the locales you want per mod, return to the main menu, then restart the game.

A prebuilt `.vmz` and the translated Chinese (`zh_cn`) pack set are published in the Release bundle. See the release-bundle `README.md` / `使用说明.md` for the end-user walkthrough.

---

## Folder Layout (Runtime)

```text
Road to Vostok/mods/
  RTV-mod-Localizer.vmz
  RTV-mod-Localizer/
    Packs/
      xp-skills-system/
        zh_cn.json
        us_us.json
      trader-improvements/
        zh_cn.json
```

Rules:

- folder name = target mod `id` (as declared in that mod's `mod.txt`)
- file name = locale id such as `zh_cn.json`
- every mod can pick its own language in MCM
- every dropdown also has a `Disabled` option that restores the original `.vmz`

---

## Runtime Data

Written under Godot's `user://` prefix:

```text
user://RTVModLocalizer/
  state.ini                  (selected locales per mod)
  Cache/                     (built localized .vmz files)
  Build/                     (temporary workspace)
  Manifest/manifest.json     (fingerprints for change detection)
  debug.log                  (overwritten each launch)
```

On Windows this resolves to `%APPDATA%/Godot/app_userdata/Road to Vostok/RTVModLocalizer/`.

---

## MCM Page

If `00ModConfigurationMenu` is installed, `RTV-mod-Localizer` registers:

- **Build Status** — last run summary
- one language dropdown per detected pack folder

Changing a dropdown triggers a rebuild immediately, but the rebuilt files only take effect after restarting the game.

---

## Pack Format

Example:

```json
{
  "pack_version": 1,
  "mod_id": "xp-skills-system",
  "mcm_mod_ids": ["XPSkillsSystem"],
  "entries": [
    {
      "match": "exact",
      "from": "XP & Skills System",
      "to": "经验与技能系统",
      "where": {
        "script_path_contains": "mods/XPSkillsSystem/Main.gd",
        "is_mcm": true,
        "mcm_mod_id": "XPSkillsSystem",
        "property": "friendlyName"
      }
    }
  ]
}
```

### Top-level fields

| Field | Type | Purpose |
|---|---|---|
| `pack_version` | int | Format version. Currently `1`. |
| `mod_id` | string | Target mod's id (matches its `mod.txt`). Also the Packs sub-folder name. |
| `mcm_mod_ids` | array | Optional MCM ids used for `mcm_mod_id` matches. First entry is also the default context. |
| `entries` | array | One entry per source literal. |

### Entry fields

- `match` — always `"exact"`. The Localizer does not evaluate `"regex"` or `"contains"` match kinds.
- `from` — the source literal exactly as it appears inside the decoded `.vmz` (including escape sequences).
- `to` — the translated literal. An empty string means "skip this entry" — useful for shipping partial packs.
- `where` — optional constraints that disambiguate multiple occurrences. When multiple entries could match the same `from` text, the Localizer picks the one whose `where` block matches **all** of its provided fields.

### Supported `where` filters

| Field | Matches |
|---|---|
| `script_path_contains` | any occurrence inside a `.gd` script whose relative path contains the given substring |
| `scene_path_contains` | `.tscn` / `.tres` whose path contains the substring |
| `owner_script_path_contains` | scene files whose attached script path contains the substring |
| `is_mcm` | `true` / `false`, matches whether the literal was detected inside an MCM register / config block |
| `mcm_mod_id` | exact string match against the MCM mod id inferred at that call site |
| `property` | exact match against the inferred display property (`text`, `title`, `friendlyName`, `description`, `tooltip_text`, …) |

When the same `from` string appears in two genuinely different contexts, author two entries with different `where` blocks. The Localizer will not over-apply one translation to the other.

---

## Development

### Repository layout

```text
RTV-mod-Localizer/
  mod.txt                              (Godot mod manifest)
  mods/
    RTVModLocalizer/
      Main.gd                          (autoload — builder + MCM integration)
  README.md
```

### Packaging a .vmz

`.vmz` is a plain ZIP archive. To produce a deployable build:

```powershell
cd RTV-mod-Localizer
python -c "import zipfile, os; zf = zipfile.ZipFile('RTV-mod-Localizer.vmz', 'w', zipfile.ZIP_DEFLATED); [zf.write(os.path.join(r,f), os.path.relpath(os.path.join(r,f))) for r, _, fs in os.walk('.') for f in fs if f != 'RTV-mod-Localizer.vmz']; zf.close()"
```

Include at minimum: `mod.txt`, `README.md`, and `mods/RTVModLocalizer/Main.gd`. Everything else is optional.

### Iteration loop

1. Edit `Main.gd`.
2. Rebuild the `.vmz` (step above).
3. Drop the `.vmz` into `…/Road to Vostok/mods/` (overwriting the previous one).
4. Launch the game.
5. Check `%APPDATA%/Godot/app_userdata/Road to Vostok/RTVModLocalizer/debug.log` and `…/modloader_conflicts.txt` for diagnostics if something fails to load.

The builder writes verbose logs on every run, so log-diffing is the fastest way to bisect pack or source changes.

### Source backup safety

The first time the Localizer touches a mod, it writes `<ModName>.vmz.rtvsrc` next to the original. Subsequent runs **always** read from `.vmz.rtvsrc` if present, so repeated localize / restore cycles never accumulate drift. **Never delete `.vmz.rtvsrc` while a localized `.vmz` is deployed** — the mod cannot restore the original without it.

---

## Contributing

Pull requests welcome for:

- new `where` filter kinds
- bug fixes in GDScript / scene / resource / config parsing
- safer skip rules for edge-case non-display literals
- new pack format features (behind `pack_version` bumps, not silent breaking changes)

Please keep in mind:

- the mod is **read-only by default** — never emit to a path other than the Localizer's own `Cache/` / `Build/` / user-facing `.vmz` deploy slot
- never translate anything not explicitly whitelisted by a pack entry; silent over-translation is the single most common user-visible failure mode
- prefer refusing to translate over translating wrong

---

## License

Released under the MIT License.
