extends Node

const MOD_ID := "rtv-mod-localizer"
const BUILDER_VERSION := "0.3.9"
const BACKUP_SUFFIX := ".rtvsrc"
const ACTIVE_SWAP_SUFFIX := ".rtvactive"
const MOD_ARCHIVE_SUFFIXES := [".vmz", ".zip"]
# Ordered (pattern, property) pairs used by _infer_gd_property_name. Earlier entries win.
# Patterns are matched against the lower-cased prefix that precedes the string literal.
# `.foo =` entries target direct assignments; `"foo"` entries target MCM dict keys.
const PROPERTY_INFERENCE_PATTERNS := [
    [".text =", "text"],
    [".tooltip_text =", "tooltip_text"],
    [".placeholder_text =", "placeholder_text"],
    [".title =", "title"],
    [".description =", "description"],
    [".label =", "label"],
    [".phrase =", "phrase"],
    ["\"tooltip\"", "tooltip"], ["'tooltip'", "tooltip"],
    ["\"description\"", "description"], ["'description'", "description"],
    ["\"label\"", "label"], ["'label'", "label"],
    ["\"category\"", "category"], ["'category'", "category"],
    ["\"friendlyname\"", "friendlyName"], ["'friendlyname'", "friendlyName"],
    ["\"modfriendlyname\"", "modFriendlyName"], ["'modfriendlyname'", "modFriendlyName"],
    ["\"modfriendlydescription\"", "modFriendlyDescription"], ["'modfriendlydescription'", "modFriendlyDescription"],
    ["\"name\"", "name"], ["'name'", "name"],
    ["\"options\"", "options"], ["'options'", "options"],
    ["\"rename\"", "rename"], ["'rename'", "rename"],
    ["\"hover\"", "hover"], ["'hover'", "hover"],
    ["\"message\"", "message"], ["'message'", "message"],
]
const DISABLED_SENTINEL := "__disabled__"
const MCM_BATCH_NONE := 0
const MCM_BATCH_ENABLE_ALL := 1
const MCM_BATCH_DISABLE_ALL := 2

const TMP_SUFFIX := ".rtvtmp"

const STATE_DIR := "user://RTVModLocalizer"
const STATE_FILE := STATE_DIR + "/state.ini"
const CACHE_DIR := STATE_DIR + "/Cache"
const BUILD_DIR := STATE_DIR + "/Build"
const MANIFEST_DIR := STATE_DIR + "/Manifest"
const MANIFEST_FILE := MANIFEST_DIR + "/manifest.json"
const DEBUG_LOG_FILE := STATE_DIR + "/debug.log"

const MCM_FILE_PATH := "user://MCM/RTVModLocalizer"
const MCM_CONFIG_FILE := MCM_FILE_PATH + "/config.ini"
const MCM_HELPERS_CANDIDATES := [
    "res://ModConfigurationMenu/Scripts/Doink Oink/MCM_Helpers.tres",
    "res://Mod Configuration Menu/Scripts/Doink Oink/MCM_Helpers.tres"
]
const MCM_DISPLAY_KEYS := [
    "name",
    "tooltip",
    "description",
    "label",
    "title",
    "modFriendlyName",
    "modFriendlyDescription",
    "friendlyName"
]
const MCM_STRING_ARRAY_KEYS := ["options"]
const OFFLINE_TEXT_EXTENSIONS := [".gd", ".tscn", ".tres", ".cfg"]
const RESOURCE_DISPLAY_PROPERTIES := ["text", "placeholder_text", "tooltip_text", "title", "tooltip", "description", "label"]
const CONFIG_DISPLAY_KEYS := ["name", "tooltip", "description", "label", "title", "friendlyName", "modFriendlyName", "modFriendlyDescription"]
const EXCLUDED_BUILD_MOD_IDS := ["rtv-mod-localizer", "doinkoink-mcm"]

const LOCALE_LABELS := {
    "ar_ar": "Arabic (ar_ar)",
    "de_de": "Deutsch (de_de)",
    "es_es": "Espanol (es_es)",
    "it_it": "Italiano (it_it)",
    "ja_jp": "Japanese (ja_jp)",
    "ko_kr": "Korean (ko_kr)",
    "pt_br": "Portugues (pt_br)",
    "ru_ru": "Russian (ru_ru)",
    "us_us": "English (US) (us_us)",
    "zh_cn": "Chinese Simplified (zh_cn)",
    "zh_tw": "Chinese Traditional (zh_tw)"
}
const LOCALE_ORDER := [
    "ar_ar",
    "de_de",
    "es_es",
    "it_it",
    "ja_jp",
    "ko_kr",
    "pt_br",
    "ru_ru",
    "us_us",
    "zh_cn",
    "zh_tw"
]
const LOCALE_FALLBACK_ORDER := [
    "zh_cn",
    "zh_tw",
    "us_us",
    "ja_jp",
    "ko_kr",
    "de_de",
    "es_es",
    "it_it",
    "pt_br",
    "ru_ru",
    "ar_ar"
]

var _pack_catalog: Dictionary = {}
var _installed_mods: Dictionary = {}
var _installed_vmz_mods: Dictionary = {}
var _selected_locales_by_mod: Dictionary = {}
var _ui_packs: Array = []
var _translation_cache: Dictionary = {}
var _current_gd_const_properties: Dictionary = {}

var _mcm_helpers: Object = null
var _mcm_registered_sources: Dictionary = {}
var _mcm_registered_last_localized: Dictionary = {}

var _manifest: Dictionary = {}
var _status_message := "No build work has run yet."
var _restart_required := false
var _built_mod_count := 0
var _restored_mod_count := 0
var _failed_mods: Array[String] = []

var _mcm_registered_once := false
var _debug_log_initialized := false

var _fmt_placeholder_re := RegEx.new()
var _alpha_run_re := RegEx.new()


func _ready() -> void:
    name = "RTVModLocalizer"
    _fmt_placeholder_re.compile("%[-+#0-9. ]*[sdif]")
    _alpha_run_re.compile("[A-Za-z]{2,}")
    # NB: directories must be ready before anything else tries to log or
    # write state, since _log() also appends to a file under STATE_DIR.
    _ensure_external_directories()
    _reset_debug_log()
    _log("INFO", "Builder %s starting (autoload _ready). platform=%s" % [BUILDER_VERSION, OS.get_name()])
    _log("INFO", "Game mods directory: %s" % _get_game_mods_directory())
    _cleanup_stale_tmp_files()

    _mcm_helpers = _try_load_mcm_helpers()
    if _mcm_helpers == null:
        _log("WARN", "MCM helpers not available; no in-game menu will be shown this session. Ensure 00ModConfigurationMenu.vmz is installed and loads before RTVModLocalizer.")

    _discover_installed_mods()
    _log("INFO", "Discovered %d installed vmz mod(s), %d folder/vmz manifest(s)." % [_installed_vmz_mods.size(), _installed_mods.size()])

    _discover_pack_catalog()
    _log("INFO", "Discovered %d mod(s) with translation packs." % _pack_catalog.size())

    _load_selected_locales_from_state()
    if _reconcile_selected_locales():
        _save_selected_locales_to_state()

    _load_ui_packs()
    _load_manifest()

    # Register MCM menu BEFORE running the builder — if the build step fails or
    # throws, the user still has a visible menu to diagnose from.
    _register_mcm_menu_once()
    _refresh_mcm_menu()
    _localize_mcm_registered_data()

    _run_builder()
    _save_manifest()

    # Builder has updated _status_message; refresh the menu values so the
    # user sees the post-build status next time they open MCM.
    _refresh_mcm_menu()
    _localize_mcm_registered_data()

    _log("INFO", "Builder finished. built=%d restored=%d failed=%d restart_required=%s" % [
        _built_mod_count,
        _restored_mod_count,
        _failed_mods.size(),
        str(_restart_required)
    ])


func _log(level: String, message: String) -> void:
    var formatted := "[RTVModLocalizer:%s] %s" % [level, message]
    if level == "WARN" or level == "ERROR":
        push_warning(formatted)
    print(formatted)
    _append_debug_log(formatted)


func _reset_debug_log() -> void:
    # Overwrite on each game launch so the log only contains the most recent
    # run. Users can attach this file when reporting issues.
    var file := FileAccess.open(DEBUG_LOG_FILE, FileAccess.WRITE)
    if file == null:
        return
    file.store_line("RTV-mod-Localizer debug log — resolved user path: %s" % ProjectSettings.globalize_path(DEBUG_LOG_FILE))
    file.store_line("Time: %s" % Time.get_datetime_string_from_system())
    file.close()
    _debug_log_initialized = true


func _append_debug_log(line: String) -> void:
    if not _debug_log_initialized:
        return
    var file := FileAccess.open(DEBUG_LOG_FILE, FileAccess.READ_WRITE)
    if file == null:
        return
    file.seek_end()
    file.store_line(line)
    file.close()


func set_mod_language(mod_id: String, locale: String) -> void:
    var normalized_mod_id := String(mod_id).strip_edges()
    if normalized_mod_id.is_empty():
        return

    var stored_value := DISABLED_SENTINEL
    var normalized_locale := _normalize_locale_id(locale)
    if not normalized_locale.is_empty():
        stored_value = normalized_locale

    if String(_selected_locales_by_mod.get(normalized_mod_id, "")) == stored_value:
        return

    _selected_locales_by_mod[normalized_mod_id] = stored_value
    _save_selected_locales_to_state()
    _load_ui_packs()
    _run_builder_for_mods([normalized_mod_id])
    _save_manifest()
    _refresh_mcm_menu()
    _localize_mcm_registered_data()


func _run_builder() -> void:
    _restart_required = false
    _built_mod_count = 0
    _restored_mod_count = 0
    _failed_mods.clear()

    var manifest_mods := _get_manifest_mods_dict()
    var buildable_lookup := _get_buildable_lookup()

    # Snapshot keys before iterating — inside the loop we mutate both
    # _installed_vmz_mods (via _restore_original_vmz / _build_and_deploy_mod)
    # and manifest_mods, so walking a live view of .keys() is unsafe.
    for mod_id_variant in _installed_vmz_mods.keys().duplicate():
        _process_single_mod_build(String(mod_id_variant), manifest_mods, buildable_lookup)

    _finalize_run_builder(manifest_mods)


func _run_builder_for_mods(mod_ids: Array) -> void:
    # Incremental rebuild path — used when a single dropdown or an MCM batch
    # action changes specific mods. Unlike _run_builder() we do NOT reset
    # _restart_required: any pending restart from an earlier mid-session action
    # must survive, because the user still needs to restart for that earlier
    # change even if this call ends up being a no-op.
    _built_mod_count = 0
    _restored_mod_count = 0
    _failed_mods.clear()

    var manifest_mods := _get_manifest_mods_dict()
    var buildable_lookup := _get_buildable_lookup()

    for mod_id_variant in mod_ids:
        var mod_id := String(mod_id_variant)
        if not _installed_vmz_mods.has(mod_id):
            continue
        _process_single_mod_build(mod_id, manifest_mods, buildable_lookup)

    _finalize_run_builder(manifest_mods)


func _get_manifest_mods_dict() -> Dictionary:
    var manifest_mods: Dictionary = _manifest.get("mods", {})
    if not (manifest_mods is Dictionary):
        manifest_mods = {}
    return manifest_mods


func _get_buildable_lookup() -> Dictionary:
    var buildable_lookup := {}
    for mod_id in _get_buildable_mod_ids():
        buildable_lookup[mod_id] = true
    return buildable_lookup


func _finalize_run_builder(manifest_mods: Dictionary) -> void:
    _manifest["mods"] = manifest_mods
    _manifest["builder_version"] = BUILDER_VERSION
    _manifest["restart_required"] = _restart_required
    _status_message = _build_status_message()
    _manifest["status_message"] = _status_message


func _process_single_mod_build(mod_id: String, manifest_mods: Dictionary, buildable_lookup: Dictionary) -> void:
    if not buildable_lookup.has(mod_id):
        if _restore_original_vmz(mod_id):
            _restored_mod_count += 1
            _restart_required = true
        manifest_mods.erase(mod_id)
        return

    var info: Dictionary = _installed_vmz_mods[mod_id]
    var locale := _get_selected_locale_for_vmz_mod(mod_id)
    if locale.is_empty():
        if _restore_original_vmz(mod_id):
            _restored_mod_count += 1
            _restart_required = true
        manifest_mods.erase(mod_id)
        return

    var locales: Dictionary = _pack_catalog.get(mod_id, {}).get("locales", {})
    if not locales.has(locale):
        push_warning("[RTVModLocalizer] Missing locale '%s' for %s" % [locale, mod_id])
        if _restore_original_vmz(mod_id):
            _restored_mod_count += 1
            _restart_required = true
        manifest_mods.erase(mod_id)
        _failed_mods.append(mod_id)
        return

    var pack_path := String(locales[locale])
    var pack := _read_pack_file(pack_path, mod_id, locale)
    if pack.is_empty():
        push_warning("[RTVModLocalizer] Failed to load pack %s" % pack_path)
        if _restore_original_vmz(mod_id):
            _restored_mod_count += 1
            _restart_required = true
        manifest_mods.erase(mod_id)
        _failed_mods.append(mod_id)
        return

    var source_path := _get_vmz_source_path(info)
    if source_path.is_empty():
        push_warning("[RTVModLocalizer] No source vmz found for %s" % mod_id)
        manifest_mods.erase(mod_id)
        _failed_mods.append(mod_id)
        return

    var fingerprint := _build_fingerprint(source_path, pack_path, locale)
    var previous: Dictionary = manifest_mods.get(mod_id, {})
    if not previous.is_empty() and String(previous.get("fingerprint", "")) == fingerprint and _has_deployed_build(info):
        previous["status"] = "ready"
        previous["locale"] = locale
        previous["pack_path"] = pack_path
        previous["source_path"] = source_path
        previous["deploy_path"] = String(info.get("deploy_path", ""))
        manifest_mods[mod_id] = previous
        return

    var result := _build_and_deploy_mod(mod_id, info, pack, pack_path, locale, fingerprint)
    if bool(result.get("ok", false)):
        _built_mod_count += 1
        _restart_required = true
        manifest_mods[mod_id] = result.get("manifest_entry", {})
    else:
        manifest_mods.erase(mod_id)
        _failed_mods.append(mod_id)
        push_warning("[RTVModLocalizer] Build failed for %s: %s" % [mod_id, String(result.get("error", "unknown error"))])
        _restore_original_vmz(mod_id)


func _build_and_deploy_mod(mod_id: String, info: Dictionary, pack: Dictionary, pack_path: String, locale: String, fingerprint: String) -> Dictionary:
    var deploy_path := String(info.get("deploy_path", ""))
    var backup_path := String(info.get("backup_path", ""))
    var source_path := _get_vmz_source_path(info)
    if deploy_path.is_empty() or source_path.is_empty():
        return {"ok": false, "error": "missing deploy/source path"}

    if backup_path.is_empty():
        backup_path = deploy_path + BACKUP_SUFFIX
        if not FileAccess.file_exists(deploy_path):
            return {"ok": false, "error": "active vmz missing for backup"}
        _remove_file_if_exists(backup_path)
        if DirAccess.rename_absolute(deploy_path, backup_path) != OK:
            return {"ok": false, "error": "failed to create backup"}
        info["backup_path"] = backup_path
        info["active_path"] = ""
        source_path = backup_path
        _installed_vmz_mods[mod_id] = info

    var build_root_abs := ProjectSettings.globalize_path(BUILD_DIR).path_join(mod_id)
    var extract_root_abs := build_root_abs.path_join("extract")
    var cache_path_abs := ProjectSettings.globalize_path(CACHE_DIR).path_join(String(info.get("filename", mod_id + ".vmz")))

    _remove_dir_recursive(build_root_abs)
    _ensure_parent_directory(cache_path_abs)

    var extract_error := _extract_vmz_to_dir(source_path, extract_root_abs)
    if extract_error != OK:
        _remove_dir_recursive(build_root_abs)
        return {"ok": false, "error": "failed to extract vmz"}

    var localize_result := _localize_build_directory(extract_root_abs, pack)
    if not bool(localize_result.get("ok", false)):
        _remove_dir_recursive(build_root_abs)
        return {"ok": false, "error": String(localize_result.get("error", "failed to localize build directory"))}

    _remove_file_if_exists(cache_path_abs)
    var pack_error := _pack_dir_to_vmz(extract_root_abs, cache_path_abs)
    _remove_dir_recursive(build_root_abs)
    if pack_error != OK:
        return {"ok": false, "error": "failed to pack localized vmz"}

    if not _deploy_vmz_file(cache_path_abs, deploy_path):
        return {"ok": false, "error": "failed to deploy localized vmz"}

    info["active_path"] = deploy_path
    info["backup_path"] = backup_path
    _installed_vmz_mods[mod_id] = info

    return {
        "ok": true,
        "manifest_entry": {
            "status": "ready",
            "fingerprint": fingerprint,
            "locale": locale,
            "pack_path": pack_path,
            "source_path": source_path,
            "deploy_path": deploy_path,
            "backup_path": backup_path,
            "cache_path": cache_path_abs,
            "builder_version": BUILDER_VERSION
        }
    }


func _restore_original_vmz(mod_id: String) -> bool:
    if not _installed_vmz_mods.has(mod_id):
        return false

    var info: Dictionary = _installed_vmz_mods[mod_id]
    var backup_path := String(info.get("backup_path", ""))
    var deploy_path := String(info.get("deploy_path", ""))
    if backup_path.is_empty() or not FileAccess.file_exists(backup_path):
        return false

    if not _restore_vmz_file(backup_path, deploy_path):
        push_warning("[RTVModLocalizer] Failed to restore %s" % mod_id)
        return false

    info["active_path"] = deploy_path
    info["backup_path"] = ""
    _installed_vmz_mods[mod_id] = info
    return true


func _load_manifest() -> void:
    _manifest = {
        "builder_version": BUILDER_VERSION,
        "mods": {},
        "restart_required": false,
        "status_message": ""
    }

    var data := _read_json(MANIFEST_FILE)
    if data is Dictionary:
        _manifest.merge(data, true)


func _save_manifest() -> void:
    _manifest["builder_version"] = BUILDER_VERSION
    _manifest["restart_required"] = _restart_required
    _manifest["status_message"] = _status_message
    _ensure_parent_directory(ProjectSettings.globalize_path(MANIFEST_FILE))

    var file := FileAccess.open(MANIFEST_FILE, FileAccess.WRITE)
    if file == null:
        push_warning("[RTVModLocalizer] Failed to write manifest")
        return
    file.store_string(JSON.stringify(_manifest, "\t"))
    file.close()


func _ensure_external_directories() -> void:
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(STATE_DIR))
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(BUILD_DIR))
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(MANIFEST_DIR))
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(MCM_FILE_PATH))
    for dir_path in _get_pack_search_directories():
        DirAccess.make_dir_recursive_absolute(dir_path)


func _cleanup_stale_tmp_files() -> void:
    # Remove stray .rtvtmp / .rtvactive files left over from a previous crash.
    var cache_dir := ProjectSettings.globalize_path(CACHE_DIR)
    _remove_matching_files_in_dir(cache_dir, [TMP_SUFFIX])

    var mods_dir := _get_game_mods_directory()
    _remove_matching_files_in_dir(mods_dir, [TMP_SUFFIX, ACTIVE_SWAP_SUFFIX])


func _remove_matching_files_in_dir(dir_path: String, suffixes: Array) -> void:
    var dir := DirAccess.open(dir_path)
    if dir == null:
        return
    dir.list_dir_begin()
    while true:
        var entry_name := dir.get_next()
        if entry_name.is_empty():
            break
        if entry_name == "." or entry_name == "..":
            continue
        if dir.current_is_dir():
            continue
        for suffix in suffixes:
            if entry_name.ends_with(String(suffix)):
                var full := dir_path.path_join(entry_name)
                _remove_file_if_exists(full)
                _log("INFO", "Cleaned up stale file: %s" % full)
                break
    dir.list_dir_end()


func _discover_installed_mods() -> void:
    _installed_mods.clear()
    _installed_vmz_mods.clear()

    var mods_dir := _get_game_mods_directory()
    var dir := DirAccess.open(mods_dir)
    if dir == null:
        return

    var folder_entries: Array[String] = []
    var file_entries: Array[String] = []

    dir.list_dir_begin()
    while true:
        var entry_name := dir.get_next()
        if entry_name.is_empty():
            break
        if entry_name == "." or entry_name == "..":
            continue
        if dir.current_is_dir():
            folder_entries.append(entry_name)
        else:
            file_entries.append(entry_name)
    dir.list_dir_end()

    folder_entries.sort()
    file_entries.sort()

    for entry_name in folder_entries:
        var full_path := mods_dir.path_join(entry_name)
        var manifest := _read_mod_manifest_from_folder(full_path)
        if manifest.is_empty():
            continue
        var mod_id := String(manifest.get("id", "")).strip_edges()
        if mod_id.is_empty():
            continue
        manifest["type"] = "folder"
        manifest["path"] = full_path
        _installed_mods[mod_id] = manifest

    for entry_name in file_entries:
        var lower := entry_name.to_lower()
        if not _has_mod_archive_suffix(lower) and not lower.ends_with(BACKUP_SUFFIX):
            continue

        var full_path := mods_dir.path_join(entry_name)
        var manifest := _read_mod_manifest_from_vmz(full_path)
        if manifest.is_empty():
            continue
        var mod_id := String(manifest.get("id", "")).strip_edges()
        if mod_id.is_empty():
            continue

        var filename := entry_name
        var is_backup := lower.ends_with(BACKUP_SUFFIX)
        if is_backup:
            filename = entry_name.substr(0, entry_name.length() - BACKUP_SUFFIX.length())

        var deploy_path := mods_dir.path_join(filename)
        var vmz_info: Dictionary = _installed_vmz_mods.get(mod_id, {
            "id": mod_id,
            "name": String(manifest.get("name", mod_id)),
            "filename": filename,
            "deploy_path": deploy_path,
            "active_path": "",
            "backup_path": ""
        })
        vmz_info["name"] = String(manifest.get("name", vmz_info.get("name", mod_id)))
        vmz_info["filename"] = filename
        vmz_info["deploy_path"] = deploy_path
        if is_backup:
            vmz_info["backup_path"] = full_path
        else:
            vmz_info["active_path"] = full_path
        _installed_vmz_mods[mod_id] = vmz_info

        if not is_backup:
            manifest["type"] = "vmz"
            manifest["path"] = full_path
            _installed_mods[mod_id] = manifest
func _get_game_mods_directory() -> String:
    return OS.get_executable_path().get_base_dir().path_join("mods")


func _has_mod_archive_suffix(lower_name: String) -> bool:
    for suffix in MOD_ARCHIVE_SUFFIXES:
        if lower_name.ends_with(String(suffix)):
            return true
    return false


func _read_mod_manifest_from_folder(folder_path: String) -> Dictionary:
    var mod_txt := folder_path.path_join("mod.txt")
    if not FileAccess.file_exists(mod_txt):
        return {}

    var file := FileAccess.open(mod_txt, FileAccess.READ)
    if file == null:
        return {}

    var text := file.get_as_text()
    file.close()
    return _parse_mod_manifest_text(text)


func _read_mod_manifest_from_vmz(vmz_path: String) -> Dictionary:
    var reader := ZIPReader.new()
    if reader.open(vmz_path) != OK:
        return {}

    if not reader.get_files().has("mod.txt"):
        reader.close()
        return {}

    var bytes: PackedByteArray = reader.read_file("mod.txt")
    reader.close()
    if bytes.is_empty():
        return {}
    return _parse_mod_manifest_text(bytes.get_string_from_utf8())


func _parse_mod_manifest_text(text: String) -> Dictionary:
    var manifest := {}
    for raw_line in text.split("\n"):
        var line := raw_line.strip_edges()
        if line.begins_with("id="):
            manifest["id"] = _parse_manifest_value(line.substr(3))
        elif line.begins_with("name="):
            manifest["name"] = _parse_manifest_value(line.substr(5))
    return manifest


func _parse_manifest_value(value: String) -> String:
    var result := value.strip_edges()
    if result.length() >= 2 and result.begins_with("\"") and result.ends_with("\""):
        return result.substr(1, result.length() - 2)
    return result


func _discover_pack_catalog() -> void:
    _pack_catalog.clear()
    for dir_path in _get_pack_search_directories():
        _discover_pack_directories(dir_path)


func _get_pack_search_directories() -> Array[String]:
    var exe_dir := OS.get_executable_path().get_base_dir()
    var directories: Array[String] = [
        exe_dir.path_join("mods/RTV-mod-Localizer/Packs")
    ]

    var unique_directories: Array[String] = []
    for dir_path in directories:
        if dir_path.is_empty():
            continue
        if unique_directories.has(dir_path):
            continue
        unique_directories.append(dir_path)
    return unique_directories


func _discover_pack_directories(root_path: String) -> void:
    var dir := DirAccess.open(root_path)
    if dir == null:
        return

    dir.list_dir_begin()
    while true:
        var entry_name := dir.get_next()
        if entry_name.is_empty():
            break
        if entry_name == "." or entry_name == "..":
            continue
        if not dir.current_is_dir():
            continue
        _discover_pack_directory(root_path.path_join(entry_name), entry_name)
    dir.list_dir_end()


func _discover_pack_directory(mod_dir_path: String, mod_id: String) -> void:
    var dir := DirAccess.open(mod_dir_path)
    if dir == null:
        return

    dir.list_dir_begin()
    while true:
        var entry_name := dir.get_next()
        if entry_name.is_empty():
            break
        if entry_name == "." or entry_name == "..":
            continue
        if dir.current_is_dir():
            continue
        if not entry_name.to_lower().ends_with(".json"):
            continue

        var locale := _normalize_locale_id(entry_name.get_basename())
        _register_pack_file(mod_id, locale, mod_dir_path.path_join(entry_name))
    dir.list_dir_end()


func _register_pack_file(mod_id: String, locale: String, pack_path: String) -> void:
    if mod_id.is_empty() or locale.is_empty():
        return
    if not _pack_catalog.has(mod_id):
        _pack_catalog[mod_id] = {
            "mod_id": mod_id,
            "locales": {}
        }

    var locales: Dictionary = _pack_catalog[mod_id]["locales"]
    locales[locale] = pack_path
    _pack_catalog[mod_id]["locales"] = locales


func _load_selected_locales_from_state() -> void:
    _selected_locales_by_mod.clear()
    var config := ConfigFile.new()
    if config.load(STATE_FILE) != OK:
        return
    if not config.has_section("Selections"):
        return

    for mod_id in config.get_section_keys("Selections"):
        var raw_value := String(config.get_value("Selections", String(mod_id), ""))
        if raw_value == DISABLED_SENTINEL:
            _selected_locales_by_mod[String(mod_id)] = DISABLED_SENTINEL
            continue

        var locale := _normalize_locale_id(raw_value)
        if locale.is_empty():
            continue
        _selected_locales_by_mod[String(mod_id)] = locale


func _save_selected_locales_to_state() -> void:
    var config := ConfigFile.new()
    for mod_id in _selected_locales_by_mod.keys():
        var value := String(_selected_locales_by_mod[mod_id])
        if value.is_empty():
            continue
        config.set_value("Selections", String(mod_id), value)
    config.save(STATE_FILE)


func _reconcile_selected_locales() -> bool:
    var changed := false

    # Snapshot keys first — we erase from _selected_locales_by_mod inside the loop.
    for mod_id_variant in _selected_locales_by_mod.keys().duplicate():
        var mod_id := String(mod_id_variant)
        if _pack_catalog.has(mod_id):
            continue
        _selected_locales_by_mod.erase(mod_id)
        changed = true

    for mod_id_variant in _pack_catalog.keys().duplicate():
        var mod_id := String(mod_id_variant)
        var locales: Dictionary = _pack_catalog[mod_id]["locales"]
        var selected := String(_selected_locales_by_mod.get(mod_id, ""))
        if selected == DISABLED_SENTINEL:
            continue
        if not selected.is_empty() and locales.has(selected):
            continue

        var default_locale := _choose_locale_for_mod(mod_id, locales)
        if default_locale.is_empty():
            if _selected_locales_by_mod.has(mod_id):
                _selected_locales_by_mod.erase(mod_id)
                changed = true
            continue

        if String(_selected_locales_by_mod.get(mod_id, "")) != default_locale:
            _selected_locales_by_mod[mod_id] = default_locale
            changed = true
    return changed


func _choose_locale_for_mod(mod_id: String, locales: Dictionary) -> String:
    var locale_ids := _get_sorted_locale_ids(locales)
    if locale_ids.is_empty():
        return ""

    var saved := String(_selected_locales_by_mod.get(mod_id, ""))
    if saved == DISABLED_SENTINEL:
        return ""
    if not saved.is_empty() and locales.has(saved):
        return saved
    if locale_ids.size() == 1:
        return String(locale_ids[0])
    return _choose_preferred_locale(locale_ids)


func _get_selected_locale_for_vmz_mod(mod_id: String) -> String:
    if not _pack_catalog.has(mod_id):
        return ""
    var locales: Dictionary = _pack_catalog[mod_id]["locales"]
    return _choose_locale_for_mod(mod_id, locales)


func _choose_preferred_locale(locales: Array[String]) -> String:
    for locale in LOCALE_FALLBACK_ORDER:
        if locales.has(locale):
            return locale
    if locales.is_empty():
        return ""
    return String(locales[0])


func _get_sorted_locale_ids(locales: Dictionary) -> Array[String]:
    var locale_ids: Array[String] = []
    for locale in locales.keys():
        locale_ids.append(String(locale))
    locale_ids.sort_custom(_sort_locale_ids)
    return locale_ids


func _sort_locale_ids(a: String, b: String) -> bool:
    var a_index := LOCALE_ORDER.find(a)
    var b_index := LOCALE_ORDER.find(b)
    if a_index >= 0 and b_index >= 0:
        return a_index < b_index
    if a_index >= 0:
        return true
    if b_index >= 0:
        return false
    return a < b


func _get_buildable_mod_ids() -> Array[String]:
    var mod_ids: Array[String] = []
    for mod_id_variant in _pack_catalog.keys():
        var mod_id := String(mod_id_variant)
        if EXCLUDED_BUILD_MOD_IDS.has(mod_id):
            continue
        if not _installed_vmz_mods.has(mod_id):
            continue
        mod_ids.append(mod_id)
    return _sort_mod_ids_by_display_name(mod_ids)


func _get_menu_mod_ids() -> Array[String]:
    var mod_ids: Array[String] = []
    for mod_id_variant in _pack_catalog.keys():
        var mod_id := String(mod_id_variant)
        if not _installed_mods.has(mod_id):
            continue
        mod_ids.append(mod_id)
    return _sort_mod_ids_by_display_name(mod_ids)


func _sort_mod_ids_by_display_name(mod_ids: Array[String]) -> Array[String]:
    var sortable: Array = []
    for mod_id in mod_ids:
        sortable.append({
            "id": mod_id,
            "name": _get_mod_display_name(mod_id).to_lower()
        })
    sortable.sort_custom(_sort_mod_rows)

    var result: Array[String] = []
    for row_variant in sortable:
        var row: Dictionary = row_variant
        result.append(String(row.get("id", "")))
    return result


func _sort_mod_rows(a: Dictionary, b: Dictionary) -> bool:
    var a_name := String(a.get("name", ""))
    var b_name := String(b.get("name", ""))
    if a_name == b_name:
        return String(a.get("id", "")) < String(b.get("id", ""))
    return a_name < b_name


func _get_mod_display_name(mod_id: String) -> String:
    if _installed_mods.has(mod_id):
        var manifest: Dictionary = _installed_mods[mod_id]
        var name := String(manifest.get("name", ""))
        if not name.is_empty():
            return name
    if _installed_vmz_mods.has(mod_id):
        return String(_installed_vmz_mods[mod_id].get("name", mod_id))
    return mod_id


func _load_ui_packs() -> void:
    _ui_packs.clear()
    _translation_cache.clear()

    for mod_id in _get_menu_mod_ids():
        var locales: Dictionary = _pack_catalog.get(mod_id, {}).get("locales", {})
        var locale := _choose_locale_for_mod(mod_id, locales)
        if locale.is_empty():
            continue
        if not locales.has(locale):
            continue
        var pack := _read_pack_file(String(locales[locale]), mod_id, locale)
        if not pack.is_empty():
            _ui_packs.append(pack)


func _read_pack_file(pack_path: String, mod_id: String, locale: String) -> Dictionary:
    var data := _read_json(pack_path)
    if not (data is Dictionary):
        return {}

    var pack: Dictionary = data.duplicate(true)
    pack["source_path"] = pack_path
    pack["pack_mod_id"] = mod_id
    pack["pack_locale"] = locale
    if not pack.has("mod_id"):
        pack["mod_id"] = mod_id

    if not pack.has("entries") or not (pack["entries"] is Array):
        return {}

    var normalized_entries: Array = []
    for raw_entry in pack["entries"]:
        if not (raw_entry is Dictionary):
            continue
        var entry: Dictionary = raw_entry.duplicate(true)
        entry["match"] = String(entry.get("match", "exact")).to_lower()
        if entry["match"] == "regex":
            var regex := RegEx.new()
            var error := regex.compile(String(entry.get("from", "")))
            if error != OK:
                push_warning("[RTVModLocalizer] Invalid regex in %s: %s" % [pack_path, String(entry.get("from", ""))])
                continue
            entry["_compiled_regex"] = regex
        normalized_entries.append(entry)

    pack["entries"] = normalized_entries
    return pack


func _normalize_locale_id(locale: String) -> String:
    return locale.strip_edges().to_lower().replace("-", "_")


func _read_json(path: String) -> Variant:
    if not FileAccess.file_exists(path):
        return null
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        return null
    var text := file.get_as_text()
    file.close()
    return JSON.parse_string(text)


func _register_mcm_menu_once() -> void:
    if _mcm_helpers == null or _mcm_registered_once:
        return

    _prepare_mcm_config_file()
    _call_mcm_register_configuration(
        _tr_self("RTV Mod Localizer", "friendlyName"),
        _tr_self("Builds localized vmz files for the next game launch. This mod no longer translates UI live during gameplay.", "description"),
        {"config.ini": _on_mcm_save}
    )
    _mcm_registered_once = true
    _log("INFO", "Registered MCM configuration page.")


func _refresh_mcm_menu() -> void:
    if _mcm_helpers == null:
        return

    # If RegisterConfiguration was never called (e.g. helpers became available
    # mid-run), fall through to the one-shot registration.
    if not _mcm_registered_once:
        _register_mcm_menu_once()
        return

    _prepare_mcm_config_file()


func _prepare_mcm_config_file() -> void:
    # Ensure the MCM config.ini exists, merge live values on top of any persisted
    # user choices, then push the result to MCM's runtime UI. _sync_mcm_values
    # writes every entry (with has_section_key fallback for fresh configs) and
    # saves to disk at the end, so the only prep needed is loading the prior file.
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(MCM_FILE_PATH))
    var config := ConfigFile.new()
    _init_mcm_categories(config)
    if FileAccess.file_exists(MCM_CONFIG_FILE):
        _call_mcm_check_configuration(config)
        config.load(MCM_CONFIG_FILE)
    _sync_mcm_values(config)
    _apply_mcm_config(config, false)


func _init_mcm_categories(config: ConfigFile) -> void:
    config.set_value("Category", "Builder", {"menu_pos": 0})
    config.set_value("Category", "Translated Mods", {"menu_pos": 1})


func _sync_mcm_values(config: ConfigFile) -> void:
    config.set_value("String", "build_status", {
        "name": _tr_self("Build Status", "name"),
        "tooltip": _tr_self("Shows the most recent builder result. If it says restart required, the rebuilt vmz files will be used on the next game launch.", "tooltip"),
        "default": _tr_self(_status_message, "description"),
        "value": _tr_self(_status_message, "description"),
        "menu_pos": 0,
        "category": "Builder"
    })
    var batch_entry: Dictionary = {}
    if config.has_section_key("Dropdown", "batch_action"):
        batch_entry = config.get_value("Dropdown", "batch_action", {})
    batch_entry["name"] = _tr_self("Batch Action", "name")
    batch_entry["tooltip"] = _tr_self("Run a one-time action for every detected translation pack. 'Enable All' keeps existing enabled choices and enables disabled mods with a default locale. 'Disable All' turns every mod localization off. Changes apply after restarting the game.", "tooltip")
    batch_entry["default"] = MCM_BATCH_NONE
    batch_entry["value"] = int(batch_entry.get("value", MCM_BATCH_NONE))
    batch_entry["options"] = _build_batch_action_labels()
    batch_entry["menu_pos"] = 1
    batch_entry["category"] = "Builder"
    config.set_value("Dropdown", "batch_action", batch_entry)

    var menu_pos := 0
    for mod_id in _get_menu_mod_ids():
        var key := _config_key_for_mod(mod_id)
        var locales: Dictionary = _pack_catalog.get(mod_id, {}).get("locales", {})
        var locale_ids := _get_sorted_locale_ids(locales)
        if locale_ids.is_empty():
            continue

        var entry: Dictionary = {}
        if config.has_section_key("Dropdown", key):
            entry = config.get_value("Dropdown", key, {})

        var current_index := _get_mcm_dropdown_index(mod_id, locale_ids)
        if entry.has("value"):
            current_index = clamp(int(entry.get("value", current_index)), 0, locale_ids.size())

        entry["name"] = _get_mod_display_name(mod_id)
        entry["tooltip"] = _tr_self("Select which translation file RTV-mod-Localizer prepares for %s (%s). Changes apply after restarting the game." % [_get_mod_display_name(mod_id), mod_id], "tooltip")
        entry["default"] = _get_mcm_dropdown_index(mod_id, locale_ids)
        entry["value"] = current_index
        entry["options"] = _build_locale_option_labels(locale_ids)
        entry["menu_pos"] = menu_pos
        entry["category"] = "Translated Mods"
        config.set_value("Dropdown", key, entry)
        menu_pos += 1

    config.save(MCM_CONFIG_FILE)


func _build_locale_option_labels(locale_ids: Array[String]) -> Array[String]:
    var labels: Array[String] = [_tr_self("Disabled", "options")]
    for locale in locale_ids:
        if LOCALE_LABELS.has(locale):
            labels.append(String(LOCALE_LABELS[locale]))
        else:
            labels.append("%s (%s)" % [locale.replace("_", " ").capitalize(), locale])
    return labels


func _build_batch_action_labels() -> Array[String]:
    return [
        _tr_self("No Action", "options"),
        _tr_self("Enable All", "options"),
        _tr_self("Disable All", "options")
    ]


func _get_mcm_dropdown_index(mod_id: String, locale_ids: Array[String]) -> int:
    var selected := String(_selected_locales_by_mod.get(mod_id, ""))
    if selected == DISABLED_SENTINEL:
        return 0

    var locale := _choose_locale_for_mod(mod_id, _pack_catalog.get(mod_id, {}).get("locales", {}))
    if locale.is_empty():
        return 0

    var locale_index := locale_ids.find(locale)
    if locale_index < 0:
        return 0
    return locale_index + 1


func _config_key_for_mod(mod_id: String) -> String:
    var key := "locale_" + mod_id.to_lower()
    var regex := RegEx.new()
    regex.compile("[^a-z0-9_]")
    return regex.sub(key, "_", true)


func _on_mcm_save(config: ConfigFile) -> void:
    _apply_mcm_config(config, true)


func _apply_mcm_config(config: ConfigFile, rebuild_after_save: bool = true) -> void:
    var changed_ids := {}
    var batch_action := MCM_BATCH_NONE

    if config.has_section_key("Dropdown", "batch_action"):
        var batch_entry: Dictionary = config.get_value("Dropdown", "batch_action", {})
        batch_action = int(batch_entry.get("value", MCM_BATCH_NONE))

    if batch_action == MCM_BATCH_ENABLE_ALL:
        for id in _enable_all_mod_locales():
            changed_ids[id] = true
    elif batch_action == MCM_BATCH_DISABLE_ALL:
        for id in _disable_all_mod_locales():
            changed_ids[id] = true

    if batch_action == MCM_BATCH_NONE:
        for mod_id in _get_menu_mod_ids():
            var key := _config_key_for_mod(mod_id)
            if not config.has_section_key("Dropdown", key):
                continue

            var locales: Dictionary = _pack_catalog.get(mod_id, {}).get("locales", {})
            var locale_ids := _get_sorted_locale_ids(locales)
            if locale_ids.is_empty():
                continue

            var entry: Dictionary = config.get_value("Dropdown", key, {})
            var index := clamp(int(entry.get("value", 0)), 0, locale_ids.size())
            var next_value := DISABLED_SENTINEL
            if index > 0:
                next_value = String(locale_ids[index - 1])

            if String(_selected_locales_by_mod.get(mod_id, "")) == next_value:
                continue
            _selected_locales_by_mod[mod_id] = next_value
            changed_ids[mod_id] = true

    if batch_action != MCM_BATCH_NONE:
        var reset_entry: Dictionary = config.get_value("Dropdown", "batch_action", {})
        reset_entry["value"] = MCM_BATCH_NONE
        config.set_value("Dropdown", "batch_action", reset_entry)
        for mod_id in _get_menu_mod_ids():
            var key := _config_key_for_mod(mod_id)
            if not config.has_section_key("Dropdown", key):
                continue
            var locales: Dictionary = _pack_catalog.get(mod_id, {}).get("locales", {})
            var locale_ids := _get_sorted_locale_ids(locales)
            if locale_ids.is_empty():
                continue
            var entry: Dictionary = config.get_value("Dropdown", key, {})
            entry["value"] = _get_mcm_dropdown_index(mod_id, locale_ids)
            config.set_value("Dropdown", key, entry)
        config.save(MCM_CONFIG_FILE)

    if changed_ids.is_empty():
        return

    _save_selected_locales_to_state()
    _load_ui_packs()

    if rebuild_after_save:
        _run_builder_for_mods(changed_ids.keys())
        _save_manifest()
        _refresh_mcm_menu()
        _localize_mcm_registered_data()


func _enable_all_mod_locales() -> Array[String]:
    var changed_ids: Array[String] = []
    for mod_id in _get_menu_mod_ids():
        var locales: Dictionary = _pack_catalog.get(mod_id, {}).get("locales", {})
        if locales.is_empty():
            continue
        var current := String(_selected_locales_by_mod.get(mod_id, ""))
        if current != DISABLED_SENTINEL and not current.is_empty() and locales.has(current):
            continue
        var next_locale := _choose_preferred_locale(_get_sorted_locale_ids(locales))
        if next_locale.is_empty():
            continue
        if current == next_locale:
            continue
        _selected_locales_by_mod[mod_id] = next_locale
        changed_ids.append(mod_id)
    return changed_ids


func _disable_all_mod_locales() -> Array[String]:
    var changed_ids: Array[String] = []
    for mod_id in _get_menu_mod_ids():
        if String(_selected_locales_by_mod.get(mod_id, "")) == DISABLED_SENTINEL:
            continue
        _selected_locales_by_mod[mod_id] = DISABLED_SENTINEL
        changed_ids.append(mod_id)
    return changed_ids


func _tr_self(text: String, property_name: String = "label") -> String:
    return _translate_ui_text(text, _build_mcm_context(property_name, MOD_ID))


func _call_mcm_check_configuration(config: ConfigFile) -> void:
    if _mcm_helpers == null:
        return
    if _mcm_helpers.has_method(&"CheckConfigurationHasUpdated"):
        _mcm_helpers.call(&"CheckConfigurationHasUpdated", MOD_ID, config, MCM_CONFIG_FILE)
    elif _mcm_helpers.has_method(&"CheckConfigruationHasUpdated"):
        _mcm_helpers.call(&"CheckConfigruationHasUpdated", MOD_ID, config, MCM_CONFIG_FILE)


func _call_mcm_register_configuration(friendly_name: String, description: String, callbacks: Dictionary) -> void:
    if _mcm_helpers == null:
        return
    if _mcm_helpers.has_method(&"RegisterConfiguration"):
        _mcm_helpers.call(&"RegisterConfiguration", MOD_ID, friendly_name, MCM_FILE_PATH, description, callbacks)
    elif _mcm_helpers.has_method(&"RegisterConfigruation"):
        _mcm_helpers.call(&"RegisterConfigruation", MOD_ID, friendly_name, MCM_FILE_PATH, description, callbacks)


func _try_load_mcm_helpers() -> Object:
    # ResourceLoader.exists() can report false for exported/remapped .tres
    # resources even when load() succeeds, so treat it as a hint only: try
    # each path first with exists(), then optimistically via load() itself.
    for helper_path in MCM_HELPERS_CANDIDATES:
        if ResourceLoader.exists(helper_path):
            var resource := load(helper_path)
            if resource != null:
                return resource
    for helper_path in MCM_HELPERS_CANDIDATES:
        var resource := load(helper_path)
        if resource != null:
            return resource
    return null


func _localize_mcm_registered_data() -> void:
    if _mcm_helpers == null or _ui_packs.is_empty():
        return
    if not _has_property(_mcm_helpers, "RegisteredMods"):
        return

    var registered: Variant = _mcm_helpers.get("RegisteredMods")
    if not (registered is Dictionary):
        return

    for mod_key in registered.keys():
        var mod_id := String(mod_key)
        var current_value := _deep_duplicate_variant(registered[mod_key])
        var current_matches_last := false
        if _mcm_registered_last_localized.has(mod_id):
            current_matches_last = current_value == _mcm_registered_last_localized[mod_id]

        if not _mcm_registered_sources.has(mod_id) or not current_matches_last:
            _mcm_registered_sources[mod_id] = _deep_duplicate_variant(current_value)

        var localized_value := _localize_mcm_variant(
            _deep_duplicate_variant(_mcm_registered_sources[mod_id]),
            mod_id,
            ""
        )
        registered[mod_key] = localized_value
        _mcm_registered_last_localized[mod_id] = _deep_duplicate_variant(localized_value)

    _mcm_helpers.set("RegisteredMods", registered)


func _localize_mcm_variant(value: Variant, mcm_mod_id: String, field_name: String) -> Variant:
    if value is Dictionary:
        var dictionary: Dictionary = value
        for key in dictionary.keys():
            var key_name := String(key)
            var child: Variant = dictionary[key]
            if child is String and MCM_DISPLAY_KEYS.has(key_name):
                dictionary[key] = _translate_ui_text(String(child), _build_mcm_context(key_name, mcm_mod_id))
            elif child is Array and MCM_STRING_ARRAY_KEYS.has(key_name):
                dictionary[key] = _localize_mcm_string_array(child, key_name, mcm_mod_id)
            elif child is Dictionary or child is Array:
                dictionary[key] = _localize_mcm_variant(child, mcm_mod_id, key_name)
        return dictionary

    if value is Array:
        if MCM_STRING_ARRAY_KEYS.has(field_name):
            return _localize_mcm_string_array(value, field_name, mcm_mod_id)
        var array: Array = value
        for i in range(array.size()):
            var child: Variant = array[i]
            if child is Dictionary or child is Array:
                array[i] = _localize_mcm_variant(child, mcm_mod_id, field_name)
        return array

    return value


func _localize_mcm_string_array(values: Array, property_name: String, mcm_mod_id: String) -> Array:
    var localized := values.duplicate()
    for i in range(localized.size()):
        if localized[i] is String:
            localized[i] = _translate_ui_text(String(localized[i]), _build_mcm_context(property_name, mcm_mod_id))
    return localized


func _translate_ui_text(source_text: String, context: Dictionary) -> String:
    if source_text.is_empty():
        return source_text
    var cache_key := _build_translation_cache_key(source_text, context)
    if _translation_cache.has(cache_key):
        return String(_translation_cache[cache_key])

    var result := _translate_with_packs(source_text, context, _ui_packs)
    _translation_cache[cache_key] = result
    return result


func _translate_pack_text(source_text: String, context: Dictionary, pack: Dictionary) -> String:
    return _translate_with_packs(source_text, context, [pack])


func _translate_pack_text_relaxed(source_text: String, context: Dictionary, pack: Dictionary) -> String:
    var translated := _translate_pack_text(source_text, context, pack)
    if translated != source_text:
        return translated

    var fallback := ""
    for entry_variant in pack.get("entries", []):
        var entry: Dictionary = entry_variant
        if String(entry.get("match", "exact")).to_lower() != "exact":
            continue
        if String(entry.get("from", "")) != source_text:
            continue
        var to_text := String(entry.get("to", ""))
        if to_text.is_empty():
            continue
        if fallback.is_empty():
            fallback = to_text
        elif fallback != to_text:
            return source_text
    if not fallback.is_empty():
        return fallback
    return source_text


func _translate_with_packs(source_text: String, context: Dictionary, packs: Array) -> String:
    var result := source_text
    for pack_variant in packs:
        var pack: Dictionary = pack_variant
        if not _pack_applies(pack, context):
            continue
        for entry_variant in pack.get("entries", []):
            var entry: Dictionary = entry_variant
            if _entry_matches(entry, result, context):
                result = _apply_entry(entry, result)
    return result


func _build_translation_cache_key(source_text: String, context: Dictionary) -> String:
    return "%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s" % [
        source_text,
        String(context.get("property", "")),
        String(context.get("node_type", "")),
        String(context.get("node_path", "")),
        String(context.get("scene_path", "")),
        String(context.get("node_script_path", "")),
        String(context.get("owner_script_path", "")),
        String(context.get("mcm_mod_id", "")),
        String(context.get("is_mcm", false))
    ]


func _pack_applies(pack: Dictionary, context: Dictionary) -> bool:
    if not bool(pack.get("enabled", true)):
        return false

    var mcm_mod_id := String(context.get("mcm_mod_id", ""))
    if not mcm_mod_id.is_empty() and not _pack_matches_mcm_target(pack, mcm_mod_id):
        return false

    var where: Variant = pack.get("where", {})
    if where is Dictionary and not _match_where(where, context):
        return false
    return true


func _pack_matches_mcm_target(pack: Dictionary, mcm_mod_id: String) -> bool:
    var aliases := _collect_pack_aliases(pack)
    if aliases.is_empty():
        return true

    var target := mcm_mod_id.to_lower()
    for alias in aliases:
        if alias.to_lower() == target:
            return true
    return false


func _collect_pack_aliases(pack: Dictionary) -> Array[String]:
    var aliases: Array[String] = []
    var candidates: Array = []
    candidates.append(pack.get("pack_mod_id", ""))
    candidates.append(pack.get("mod_id", ""))
    var mod_aliases: Variant = pack.get("mod_id_aliases", [])
    var mcm_ids: Variant = pack.get("mcm_mod_ids", [])
    if mod_aliases is Array:
        candidates.append_array(mod_aliases)
    if mcm_ids is Array:
        candidates.append_array(mcm_ids)

    for candidate in candidates:
        var text := String(candidate).strip_edges()
        if text.is_empty():
            continue
        if aliases.has(text):
            continue
        aliases.append(text)
    return aliases


func _entry_matches(entry: Dictionary, text: String, context: Dictionary) -> bool:
    var where: Variant = entry.get("where", {})
    if where is Dictionary and not _match_where(where, context):
        return false

    var match_type := String(entry.get("match", "exact")).to_lower()
    var from_text := String(entry.get("from", ""))
    match match_type:
        "exact":
            return text == from_text
        "contains":
            return text.contains(from_text)
        "regex":
            var regex: RegEx = entry.get("_compiled_regex", null)
            return regex != null and regex.search(text) != null
        _:
            return false


func _apply_entry(entry: Dictionary, text: String) -> String:
    var match_type := String(entry.get("match", "exact")).to_lower()
    var from_text := String(entry.get("from", ""))
    var to_text := String(entry.get("to", ""))
    match match_type:
        "exact":
            return to_text
        "contains":
            return text.replace(from_text, to_text)
        "regex":
            var regex: RegEx = entry.get("_compiled_regex", null)
            if regex == null:
                return text
            return regex.sub(text, to_text, true)
        _:
            return text


func _match_where(where: Dictionary, context: Dictionary) -> bool:
    for key in where.keys():
        var expected: Variant = where[key]
        match String(key):
            "node_type":
                if not _match_value(String(context.get("node_type", "")), expected, "exact"):
                    return false
            "property":
                if not _match_value(String(context.get("property", "")), expected, "exact"):
                    return false
            "node_path_contains":
                if not _match_value(String(context.get("node_path", "")), expected, "contains"):
                    return false
            "scene_path_contains":
                if not _match_value(String(context.get("scene_path", "")), expected, "contains"):
                    return false
            "script_path_contains":
                if not _match_value(String(context.get("script_scope", "")), expected, "contains"):
                    return false
            "owner_script_path_contains":
                if not _match_value(String(context.get("owner_script_path", "")), expected, "contains"):
                    return false
            "is_mcm":
                if bool(context.get("is_mcm", false)) != bool(expected):
                    return false
            "mcm_mod_id":
                if not _match_value(String(context.get("mcm_mod_id", "")), expected, "exact_ci"):
                    return false
            _:
                return false
    return true


func _match_value(actual: String, expected: Variant, mode: String) -> bool:
    # mode: "exact" | "exact_ci" | "contains"
    var cmp := actual.to_lower() if mode == "exact_ci" else actual
    var items: Array = expected if expected is Array else [expected]
    for item in items:
        var target := String(item)
        if mode == "exact_ci":
            target = target.to_lower()
        if mode == "contains":
            if cmp.contains(target):
                return true
        else:
            if cmp == target:
                return true
    return false


func _build_mcm_context(property_name: String, mcm_mod_id: String) -> Dictionary:
    return {
        "property": property_name,
        "node_type": "MCMMetadata",
        "node_path": "",
        "scene_path": "res://ModConfigurationMenu",
        "node_script_path": "res://ModConfigurationMenu",
        "owner_script_path": "res://ModConfigurationMenu",
        "script_scope": "res://ModConfigurationMenu | %s" % mcm_mod_id,
        "is_mcm": true,
        "mcm_mod_id": mcm_mod_id
    }


func _build_file_context(relative_path: String, pack: Dictionary, property_name: String = "", is_mcm_context: bool = false) -> Dictionary:
    var mcm_mod_id := String(pack.get("mod_id", ""))
    var mcm_ids: Variant = pack.get("mcm_mod_ids", [])
    if mcm_ids is Array and not mcm_ids.is_empty():
        mcm_mod_id = String(mcm_ids[0])

    return {
        "property": property_name,
        "node_type": "",
        "node_path": "",
        "scene_path": relative_path if relative_path.to_lower().ends_with(".tscn") or relative_path.to_lower().ends_with(".tres") else "",
        "node_script_path": relative_path,
        "owner_script_path": relative_path,
        "script_scope": relative_path,
        "is_mcm": is_mcm_context,
        "mcm_mod_id": mcm_mod_id
    }


func _has_property(target: Object, property_name: String) -> bool:
    for property_info in target.get_property_list():
        if String(property_info.get("name", "")) == property_name:
            return true
    return false


func _deep_duplicate_variant(value: Variant) -> Variant:
    if value is Dictionary:
        return value.duplicate(true)
    if value is Array:
        return value.duplicate(true)
    return value


func _build_status_message() -> String:
    if _failed_mods.size() > 0:
        return "Build finished with failures: %s. Original vmz files were kept where possible." % ", ".join(_failed_mods)
    if _restart_required:
        return "Rebuilt %d mod(s) and restored %d mod(s). Restart the game to load the updated vmz files." % [_built_mod_count, _restored_mod_count]
    return "No rebuild was needed. The current vmz deployment already matches the selected language packs."


func _build_fingerprint(source_path: String, pack_path: String, locale: String) -> String:
    var source_size := _get_file_size(source_path)
    var pack_size := _get_file_size(pack_path)
    var source_mtime := FileAccess.get_modified_time(source_path)
    var pack_mtime := FileAccess.get_modified_time(pack_path)
    return "%s|%d|%d|%s|%s|%d|%d|%s" % [
        source_path,
        source_size,
        source_mtime,
        locale,
        pack_path,
        pack_size,
        pack_mtime,
        BUILDER_VERSION
    ]


func _get_file_size(path: String) -> int:
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        return -1
    var size := file.get_length()
    file.close()
    return size


func _get_vmz_source_path(info: Dictionary) -> String:
    var backup_path := String(info.get("backup_path", ""))
    if not backup_path.is_empty() and FileAccess.file_exists(backup_path):
        return backup_path
    var active_path := String(info.get("active_path", ""))
    if not active_path.is_empty() and FileAccess.file_exists(active_path):
        return active_path
    return ""


func _has_deployed_build(info: Dictionary) -> bool:
    var active_path := String(info.get("active_path", ""))
    var backup_path := String(info.get("backup_path", ""))
    return not active_path.is_empty() and FileAccess.file_exists(active_path) and not backup_path.is_empty() and FileAccess.file_exists(backup_path)


func _extract_vmz_to_dir(source_path: String, output_dir: String) -> int:
    _remove_dir_recursive(output_dir)
    DirAccess.make_dir_recursive_absolute(output_dir)

    var reader := ZIPReader.new()
    var open_error := reader.open(source_path)
    if open_error != OK:
        return open_error

    for entry_path in reader.get_files():
        if entry_path.ends_with("/"):
            DirAccess.make_dir_recursive_absolute(output_dir.path_join(entry_path.trim_suffix("/")))
            continue

        var bytes: PackedByteArray = reader.read_file(entry_path)
        var absolute_path := output_dir.path_join(entry_path)
        _ensure_parent_directory(absolute_path)
        var file := FileAccess.open(absolute_path, FileAccess.WRITE)
        if file == null:
            reader.close()
            return ERR_CANT_CREATE
        file.store_buffer(bytes)
        file.close()

    reader.close()
    return OK


func _localize_build_directory(root_dir: String, pack: Dictionary) -> Dictionary:
    var dir := DirAccess.open(root_dir)
    if dir == null:
        return {"ok": false, "error": "missing build directory"}

    var root_length := root_dir.length() + 1
    return _localize_directory_recursive(root_dir, root_length, pack)


func _localize_directory_recursive(dir_path: String, root_length: int, pack: Dictionary) -> Dictionary:
    var dir := DirAccess.open(dir_path)
    if dir == null:
        return {"ok": false, "error": "failed to open build directory"}

    dir.list_dir_begin()
    while true:
        var entry_name := dir.get_next()
        if entry_name.is_empty():
            break
        if entry_name == "." or entry_name == "..":
            continue

        var entry_path := dir_path.path_join(entry_name)
        if dir.current_is_dir():
            var child_result := _localize_directory_recursive(entry_path, root_length, pack)
            if not bool(child_result.get("ok", false)):
                dir.list_dir_end()
                return child_result
            continue

        if not _is_localizable_text_file(entry_name):
            continue

        var relative_path := entry_path.substr(root_length)
        if not _localize_build_file(entry_path, relative_path, pack):
            dir.list_dir_end()
            return {"ok": false, "error": "failed to localize %s" % relative_path}
    dir.list_dir_end()
    return {"ok": true}


func _localize_build_file(absolute_path: String, relative_path: String, pack: Dictionary) -> bool:
    var file := FileAccess.open(absolute_path, FileAccess.READ)
    if file == null:
        return false
    var text := file.get_as_text()
    file.close()

    var localized := _localize_text_file(text, relative_path, pack)
    if localized == text:
        return true

    file = FileAccess.open(absolute_path, FileAccess.WRITE)
    if file == null:
        return false
    file.store_string(localized)
    file.close()
    return true


func _is_localizable_text_file(file_name: String) -> bool:
    var lower := file_name.to_lower()
    for ext in OFFLINE_TEXT_EXTENSIONS:
        if lower.ends_with(ext):
            return true
    return false


func _localize_text_file(text: String, relative_path: String, pack: Dictionary) -> String:
    var lower := relative_path.to_lower()
    if lower.ends_with(".gd"):
        return _localize_gd_source(text, relative_path, pack)
    if lower.ends_with(".tscn") or lower.ends_with(".tres"):
        return _localize_resource_text(text, relative_path, pack)
    if lower.ends_with(".cfg"):
        return _localize_cfg_text(text, relative_path, pack)
    return text


func _localize_gd_source(text: String, relative_path: String, pack: Dictionary) -> String:
    # Build a map of const-identifier → display-property for every identifier
    # used as an argument at a known display position (e.g. friendlyName) in a
    # RegisterConfiguration-like call. Consulted by _is_non_display_gd_prefix
    # and Pass 2 so that `const MOD_NAME := "..."` declarations get translated
    # via the mapped property even though const declarations are otherwise
    # treated as non-display.
    _current_gd_const_properties = _collect_gd_const_display_properties(text)
    text = _localize_gd_register_calls(text, relative_path, pack)
    text = _localize_gd_mcm_lines(text, relative_path, pack)
    text = _localize_gd_display_arrays(text, relative_path, pack)
    text = _localize_gd_formatted_item_names(text, relative_path, pack)
    text = _localize_trader_display_names(text, relative_path, pack)
    var line_contexts := _build_gd_line_contexts(text)

    # Pass 1: classify every string literal as safe (has a recognized display property
    # like .text=) or unsafe (e.g. .name=, dict-key, indexer). A literal is globally
    # ambiguous if it occurs in both categories somewhere in the file; such literals are
    # excluded from the fragment-fallback translation branch in pass 2 to avoid
    # over-translation of names/identifiers that happen to match a pack entry.
    var states := {}
    var line_start := 0
    var line_number := 1
    var i := 0
    while i < text.length():
        var ch := text[i]
        if ch == "\n":
            line_start = i + 1
            line_number += 1
            i += 1
            continue
        if ch == "#":
            var eol_pos := text.find("\n", i)
            if eol_pos < 0:
                eol_pos = text.length()
            i = eol_pos
            continue
        if ch == "\"" or ch == "'":
            var scan := _scan_string_literal(text, i, ch)
            if scan.is_empty():
                i += 1
                continue
            var lit := String(scan.get("value", ""))
            var end_idx := int(scan.get("end", i + 1))
            var pre := text.substr(line_start, i - line_start)
            var suf := text.substr(end_idx)
            var prop := _infer_gd_property_name(pre)
            if prop == "config_key":
                i = end_idx
                continue
            var mcm_ctx := bool(line_contexts.get(line_number, false)) or _infer_gd_is_mcm_context(pre)
            var is_safe := not prop.is_empty() \
                and not _is_gd_indexer_key(pre, suf) \
                and not _is_gd_dict_key(suf) \
                and not _should_skip_gd_literal(lit, pre, prop, mcm_ctx)
            if not states.has(lit):
                states[lit] = {"safe": false, "unsafe": false}
            var st: Dictionary = states[lit]
            st["safe"] = bool(st.get("safe", false)) or is_safe
            st["unsafe"] = bool(st.get("unsafe", false)) or not is_safe
            states[lit] = st
            i = end_idx
            continue
        i += 1

    var ambiguous_literals := {}
    for lit_key in states.keys():
        var st: Dictionary = states[lit_key]
        if bool(st.get("safe", false)) and bool(st.get("unsafe", false)):
            ambiguous_literals[String(lit_key)] = true

    # Pass 2: walk again and emit the translated output.
    var output := ""
    line_start = 0
    line_number = 1
    i = 0

    while i < text.length():
        var ch := text[i]
        if ch == "\n":
            output += ch
            line_start = i + 1
            line_number += 1
            i += 1
            continue

        # Skip line comments (`# ...`) verbatim. GDScript has no multi-line
        # comment syntax, so `#` always runs to end of line. Critically, this
        # prevents stray apostrophes inside comments (e.g. `# they're great`)
        # from being mistaken for string-literal starts, which would cause
        # _scan_string_literal to greedily consume text across many lines.
        if ch == "#":
            var eol := text.find("\n", i)
            if eol < 0:
                eol = text.length()
            output += text.substr(i, eol - i)
            i = eol
            continue

        if ch == "\"" or ch == "'":
            var parse_result := _scan_string_literal(text, i, ch)
            if parse_result.is_empty():
                output += ch
                i += 1
                continue

            var literal := String(parse_result.get("value", ""))
            var prefix := text.substr(line_start, i - line_start)
            var end_index := int(parse_result.get("end", i + 1))
            var property_name := _infer_gd_property_name(prefix)
            var is_mcm_context := bool(line_contexts.get(line_number, false)) or _infer_gd_is_mcm_context(prefix)
            if property_name.is_empty():
                # const IDENT := "..." where IDENT is used at a known display
                # argument position in a RegisterConfiguration-like call:
                # promote the literal to the mapped display property so the
                # pack's {where.property, where.is_mcm} entry matches.
                var const_ident := _extract_const_identifier_from_prefix(prefix)
                if not const_ident.is_empty() and _current_gd_const_properties.has(const_ident):
                    property_name = String(_current_gd_const_properties[const_ident])
                    is_mcm_context = true
            var suffix := text.substr(end_index)
            var translated := literal
            var in_safe_context := property_name != "config_key" \
                and not _is_gd_dict_key(suffix) \
                and not _is_gd_indexer_key(prefix, suffix)
            if in_safe_context and not _should_skip_gd_literal(literal, prefix, property_name, is_mcm_context):
                # Strict path: literal is in a recognized display context.
                # The per-occurrence property check (.text=, tooltip dict, etc.)
                # already proves THIS site is safe, so the global ambiguity guard
                # is intentionally not applied here — e.g. `button.text = "Skills"`
                # must still translate even when `ui.name = "Skills"` elsewhere in
                # the same file makes the literal globally ambiguous.
                var context := _build_file_context(relative_path, pack, property_name, is_mcm_context)
                translated = _translate_pack_text(literal, context, pack)
            elif in_safe_context \
                and property_name.is_empty() \
                and not ambiguous_literals.has(literal) \
                and not _should_skip_gd_literal(literal, prefix, property_name, is_mcm_context, false):
                # Fragment fallback: the literal is in an expression-level position
                # (e.g. `"+" + str(x) + " Max HP"`) with no inferred display property,
                # but the pack may contain this exact `from` text from another
                # extraction path (like a display-array entry). Use the relaxed
                # translator, which ignores `where` constraints and matches on
                # `from` text alone.
                var context := _build_file_context(relative_path, pack, "", is_mcm_context)
                translated = _translate_pack_text_relaxed(literal, context, pack)
            output += ch + _escape_string_literal(translated, ch) + ch
            i = end_index
            continue

        output += ch
        i += 1
    return output


func _localize_gd_mcm_lines(text: String, relative_path: String, pack: Dictionary) -> String:
    var lines := text.split("\n", true)
    var line_contexts := _build_gd_line_contexts(text)
    var changed := false

    for i in range(lines.size()):
        var line_number := i + 1
        if not bool(line_contexts.get(line_number, false)):
            continue

        var line := lines[i]
        var assignment := _find_gd_property_assignment(line)
        if assignment.is_empty():
            continue

        var property_name := String(assignment.get("property", ""))
        var value_start := int(assignment.get("value_start", -1))
        if value_start < 0:
            continue

        var key_part := line.substr(0, value_start)
        var value_part := line.substr(value_start).strip_edges()

        if property_name == "options":
            var block_result := _collect_gd_array_block(lines, i, value_start)
            var block_text := String(block_result.get("text", value_part))
            var end_line := int(block_result.get("end_line", i))
            var localized_options := _localize_gd_options_value(block_text, relative_path, pack)
            if localized_options != block_text:
                var replacement_lines := localized_options.split("\n", true)
                lines[i] = line.substr(0, value_start) + " " + replacement_lines[0].strip_edges(true, false)
                var cursor := i + 1
                for part_index in range(1, replacement_lines.size()):
                    if cursor <= end_line:
                        lines[cursor] = replacement_lines[part_index]
                    else:
                        lines.insert(cursor, replacement_lines[part_index])
                        end_line += 1
                    cursor += 1
                while cursor <= end_line:
                    lines.remove_at(cursor)
                    end_line -= 1
                changed = true
            continue

        if not value_part.begins_with("\"") and not value_part.begins_with("'"):
            continue

        var delimiter := value_part.substr(0, 1)
        var parse_result := _scan_string_literal(value_part, 0, delimiter)
        if parse_result.is_empty():
            continue

        var literal := String(parse_result.get("value", ""))
        var context := _build_file_context(relative_path, pack, property_name, true)
        var translated := _translate_pack_text(literal, context, pack)
        if translated == literal:
            continue

        var escaped := _escape_string_literal(translated, delimiter)
        var suffix := value_part.substr(int(parse_result.get("end", 1)))
        lines[i] = key_part + " " + delimiter + escaped + delimiter + suffix
        changed = true

    if not changed:
        return text
    return "\n".join(lines)


func _localize_gd_register_calls(text: String, relative_path: String, pack: Dictionary) -> String:
    var patterns := [
        "RegisterConfiguration(",
        "RegisterConfigruation(",
        "_call_mcm_register_configuration(",
        ".call("
    ]
    var output := text
    var search_index := 0

    while search_index < output.length():
        var matched_pattern := ""
        var matched_index := -1
        for pattern in patterns:
            var pos := output.find(pattern, search_index)
            if pos >= 0 and (matched_index < 0 or pos < matched_index):
                matched_pattern = pattern
                matched_index = pos
        if matched_index < 0:
            break

        var block_end := _find_gd_call_block_end(output, matched_index)
        if block_end < 0:
            break

        var block := output.substr(matched_index, block_end - matched_index)
        if matched_pattern == ".call(" and not block.begins_with(".call("):
            search_index = block_end
            continue
        var localized_block := _localize_gd_register_call_block(block, relative_path, pack, matched_pattern)
        if localized_block != block:
            output = output.substr(0, matched_index) + localized_block + output.substr(block_end)
            search_index = matched_index + localized_block.length()
        else:
            search_index = block_end
    return output


func _localize_gd_register_call_block(block: String, relative_path: String, pack: Dictionary, matched_pattern: String) -> String:
    var open_paren := block.find("(")
    if open_paren < 0:
        return block

    var result := ""
    var arg_index := 0
    var depth := 1
    var i := open_paren + 1
    result += block.substr(0, i)

    while i < block.length():
        var ch := block[i]
        if ch == "\"" or ch == "'":
            var parse_result := _scan_string_literal(block, i, ch)
            if parse_result.is_empty():
                result += ch
                i += 1
                continue

            var literal := String(parse_result.get("value", ""))
            var property_name := ""
            if matched_pattern == ".call(":
                if block.substr(6).strip_edges(true, false).begins_with("register_method"):
                    if arg_index == 2:
                        property_name = "friendlyName"
                    elif arg_index == 4:
                        property_name = "description"
            elif matched_pattern == "_call_mcm_register_configuration(":
                if arg_index == 0:
                    property_name = "friendlyName"
                elif arg_index == 1:
                    property_name = "description"
            else:
                if arg_index == 1:
                    property_name = "friendlyName"
                elif arg_index == 3:
                    property_name = "description"

            var translated := literal
            if not property_name.is_empty():
                var context := _build_file_context(relative_path, pack, property_name, true)
                translated = _translate_pack_text(literal, context, pack)
            result += ch + _escape_string_literal(translated, ch) + ch
            i = int(parse_result.get("end", i + 1))
            continue

        result += ch
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth <= 0:
                break
        elif ch == "," and depth == 1:
            arg_index += 1
        i += 1

    if i + 1 < block.length():
        result += block.substr(i + 1)
    return result


func _collect_gd_const_display_properties(text: String) -> Dictionary:
    # Scan every RegisterConfiguration-like call and record any identifier
    # argument passed at a display position. Enables translation of
    # `const MOD_NAME := "Immersive Ammo Check"` declarations whose literal
    # only reaches MCM via the identifier — the pack entry carries the
    # display property (friendlyName/description), but Pass 2 otherwise
    # treats const declarations as non-display and skips them.
    var map: Dictionary = {}
    var patterns := [
        "RegisterConfiguration(",
        "RegisterConfigruation(",
        "_call_mcm_register_configuration("
    ]
    for pattern in patterns:
        var search_index := 0
        while search_index < text.length():
            var found := text.find(pattern, search_index)
            if found < 0:
                break
            var block_end := _find_gd_call_block_end(text, found)
            if block_end < 0:
                break
            var block := text.substr(found, block_end - found)
            _scan_gd_register_block_for_const_idents(block, pattern, map)
            search_index = block_end
    return map


func _scan_gd_register_block_for_const_idents(block: String, matched_pattern: String, map: Dictionary) -> void:
    var open_paren := block.find("(")
    if open_paren < 0:
        return
    var arg_index := 0
    var depth := 1
    var i := open_paren + 1
    var current_arg := ""
    while i < block.length():
        var ch := block[i]
        if ch == "\"" or ch == "'":
            var scan := _scan_string_literal(block, i, ch)
            if scan.is_empty():
                current_arg += ch
                i += 1
                continue
            var end_idx := int(scan.get("end", i + 1))
            current_arg += block.substr(i, end_idx - i)
            i = end_idx
            continue
        if ch == "(" or ch == "[" or ch == "{":
            depth += 1
            current_arg += ch
            i += 1
            continue
        if ch == ")" or ch == "]" or ch == "}":
            depth -= 1
            if depth == 0:
                _record_gd_const_arg(current_arg, arg_index, matched_pattern, map)
                return
            current_arg += ch
            i += 1
            continue
        if ch == "," and depth == 1:
            _record_gd_const_arg(current_arg, arg_index, matched_pattern, map)
            current_arg = ""
            arg_index += 1
            i += 1
            continue
        current_arg += ch
        i += 1


func _record_gd_const_arg(arg_text: String, arg_index: int, matched_pattern: String, map: Dictionary) -> void:
    var arg := arg_text.strip_edges()
    if arg.is_empty():
        return
    if not _is_identifier_only(arg):
        return
    var property_name := ""
    if matched_pattern == "_call_mcm_register_configuration(":
        if arg_index == 0:
            property_name = "friendlyName"
        elif arg_index == 1:
            property_name = "description"
    else:
        if arg_index == 1:
            property_name = "friendlyName"
        elif arg_index == 3:
            property_name = "description"
    if property_name.is_empty():
        return
    map[arg] = property_name


func _extract_const_identifier_from_prefix(prefix: String) -> String:
    # Returns IDENT if `prefix` matches a `const IDENT [: TYPE] [:=|=]`
    # declaration header (with arbitrary leading whitespace); empty otherwise.
    var stripped := prefix.strip_edges(false, true).strip_edges(true, false)
    if not stripped.begins_with("const "):
        return ""
    var rest := stripped.substr(6).strip_edges(true, false)
    var ident := ""
    for j in range(rest.length()):
        var code := rest.unicode_at(j)
        var is_letter := (code >= 65 and code <= 90) or (code >= 97 and code <= 122) or code == 95
        var is_digit := code >= 48 and code <= 57
        if j == 0:
            if is_letter:
                ident += rest[j]
            else:
                return ""
        else:
            if is_letter or is_digit:
                ident += rest[j]
            else:
                break
    return ident


func _find_gd_call_block_end(text: String, start_index: int) -> int:
    var depth := 0
    var i := start_index
    while i < text.length():
        var ch := text[i]
        if ch == "\"" or ch == "'":
            var parse_result := _scan_string_literal(text, i, ch)
            if parse_result.is_empty():
                return -1
            i = int(parse_result.get("end", i + 1))
            continue
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return -1


func _find_gd_property_assignment(line: String) -> Dictionary:
    var patterns := [
        {"property": "title", "token": "\"title\" ="},
        {"property": "title", "token": "\"title\":"},
        {"property": "title", "token": "'title' ="},
        {"property": "title", "token": "'title':"},
        {"property": "tooltip", "token": "\"tooltip\" ="},
        {"property": "tooltip", "token": "\"tooltip\":"},
        {"property": "tooltip", "token": "'tooltip' ="},
        {"property": "tooltip", "token": "'tooltip':"},
        {"property": "description", "token": "\"description\" ="},
        {"property": "description", "token": "\"description\":"},
        {"property": "description", "token": "'description' ="},
        {"property": "description", "token": "'description':"},
        {"property": "label", "token": "\"label\" ="},
        {"property": "label", "token": "\"label\":"},
        {"property": "label", "token": "'label' ="},
        {"property": "label", "token": "'label':"},
        {"property": "category", "token": "\"category\" ="},
        {"property": "category", "token": "\"category\":"},
        {"property": "category", "token": "'category' ="},
        {"property": "category", "token": "'category':"},
        {"property": "friendlyName", "token": "\"friendlyName\" ="},
        {"property": "friendlyName", "token": "\"friendlyName\":"},
        {"property": "friendlyName", "token": "'friendlyName' ="},
        {"property": "friendlyName", "token": "'friendlyName':"},
        {"property": "modFriendlyName", "token": "\"modFriendlyName\" ="},
        {"property": "modFriendlyName", "token": "\"modFriendlyName\":"},
        {"property": "modFriendlyName", "token": "'modFriendlyName' ="},
        {"property": "modFriendlyName", "token": "'modFriendlyName':"},
        {"property": "modFriendlyDescription", "token": "\"modFriendlyDescription\" ="},
        {"property": "modFriendlyDescription", "token": "\"modFriendlyDescription\":"},
        {"property": "modFriendlyDescription", "token": "'modFriendlyDescription' ="},
        {"property": "modFriendlyDescription", "token": "'modFriendlyDescription':"},
        {"property": "name", "token": "\"name\" ="},
        {"property": "name", "token": "\"name\":"},
        {"property": "name", "token": "'name' ="},
        {"property": "name", "token": "'name':"},
        {"property": "options", "token": "\"options\" ="},
        {"property": "options", "token": "\"options\":"},
        {"property": "options", "token": "'options' ="},
        {"property": "options", "token": "'options':"}
    ]

    var best_index := -1
    var best_property := ""
    var best_token := ""
    for pattern_variant in patterns:
        var pattern: Dictionary = pattern_variant
        var token := String(pattern.get("token", ""))
        var index := line.find(token)
        if index < 0:
            continue
        if best_index < 0 or index < best_index:
            best_index = index
            best_property = String(pattern.get("property", ""))
            best_token = token

    if best_index < 0:
        return {}

    return {
        "property": best_property,
        "value_start": best_index + best_token.length()
    }


func _collect_gd_array_block(lines: Array, start_index: int, value_start: int) -> Dictionary:
    var text := String(lines[start_index]).substr(value_start)
    var end_line := start_index
    var depth := 0
    var started := false

    for ch in text:
        if ch == "[":
            depth += 1
            started = true
        elif ch == "]" and started:
            depth -= 1
    while started and depth > 0 and end_line + 1 < lines.size():
        end_line += 1
        var next_line := String(lines[end_line])
        text += "\n" + next_line
        for ch in next_line:
            if ch == "[":
                depth += 1
            elif ch == "]":
                depth -= 1
    return {
        "text": text,
        "end_line": end_line
    }


func _localize_gd_options_value(value_part: String, relative_path: String, pack: Dictionary) -> String:
    var result := ""
    var i := 0
    var changed := false
    var context := _build_file_context(relative_path, pack, "options", true)

    while i < value_part.length():
        var ch := value_part[i]
        if ch == "\"" or ch == "'":
            var parse_result := _scan_string_literal(value_part, i, ch)
            if parse_result.is_empty():
                result += ch
                i += 1
                continue

            var literal := String(parse_result.get("value", ""))
            var translated := _translate_pack_text_relaxed(literal, context, pack)
            result += ch + _escape_string_literal(translated, ch) + ch
            if translated != literal:
                changed = true
            i = int(parse_result.get("end", i + 1))
            continue

        result += ch
        i += 1

    if not changed:
        return value_part
    return result


func _localize_gd_display_arrays(text: String, relative_path: String, pack: Dictionary) -> String:
    var lines := text.split("\n", true)
    var line_contexts := _build_gd_line_contexts(text)
    var changed := false

    for i in range(lines.size()):
        var declaration := _parse_gd_string_array_declaration(String(lines[i]))
        if declaration.is_empty():
            continue

        var variable_name := String(declaration.get("variable", ""))
        var declaration_type := String(declaration.get("kind", ""))
        var usage := _get_gd_display_array_usage(lines, line_contexts, variable_name, declaration_type == "const")
        if not bool(usage.get("safe", false)):
            continue

        var is_mcm := bool(usage.get("is_mcm", false))
        var block := String(declaration.get("block", ""))
        var localized_block := _localize_gd_array_literals(block, relative_path, pack, is_mcm)
        if localized_block == block:
            continue

        var start_index := int(declaration.get("block_start", -1))
        var end_index := int(declaration.get("block_end", -1))
        if start_index < 0 or end_index < start_index:
            continue

        var line := String(lines[i])
        lines[i] = line.substr(0, start_index) + localized_block + line.substr(end_index + 1)
        changed = true

    if not changed:
        return text
    return "\n".join(lines)


func _parse_gd_string_array_declaration(line: String) -> Dictionary:
    var trimmed := line.strip_edges()
    if trimmed.begins_with("#"):
        return {}

    var kind := ""
    var body := ""
    if trimmed.begins_with("const "):
        kind = "const"
        body = trimmed.substr(6)
    elif trimmed.begins_with("var "):
        kind = "var"
        body = trimmed.substr(4)
    else:
        return {}

    var equal_index := body.find("=")
    if equal_index < 0:
        return {}

    var name_part := body.substr(0, equal_index).strip_edges()
    var colon_index := name_part.find(":")
    if colon_index >= 0:
        name_part = name_part.substr(0, colon_index).strip_edges()
    if name_part.is_empty():
        return {}

    var bracket_start := line.find("[")
    var bracket_end := line.rfind("]")
    if bracket_start < 0 or bracket_end < bracket_start:
        return {}

    var block := line.substr(bracket_start, bracket_end - bracket_start + 1)
    if block.find("\"") < 0 and block.find("'") < 0:
        return {}

    return {
        "kind": kind,
        "variable": name_part,
        "block": block,
        "block_start": bracket_start,
        "block_end": bracket_end
    }


func _regex_escape(text: String) -> String:
    var result := ""
    for i in range(text.length()):
        var c := text[i]
        if "\\.^$*+?()[]{}|".find(c) >= 0:
            result += "\\"
        result += c
    return result


func _get_gd_display_array_usage(lines: Array, line_contexts: Dictionary, variable_name: String, const_only: bool) -> Dictionary:
    var regex := RegEx.new()
    regex.compile("\\b" + _regex_escape(variable_name) + "\\b")
    var has_display := false
    var all_safe := true
    var any_mcm := false

    for line_index in range(lines.size()):
        var line := String(lines[line_index])
        var trimmed := line.strip_edges()
        if trimmed.is_empty():
            continue
        if const_only and trimmed.begins_with("const "):
            continue
        if not const_only and trimmed.begins_with("var "):
            continue
        var match := regex.search(line)
        if match == null:
            continue

        # Skip method / attribute accesses on the variable itself (e.g. `foo.size()`,
        # `foo.clear()`, `foo.append(x)`). These don't dereference string elements,
        # so they neither confirm display intent nor threaten safety.
        var end_pos := match.get_end()
        var after_ch := ""
        if end_pos < line.length():
            after_ch = line.substr(end_pos, 1)
        if after_ch == ".":
            continue

        var prefix := line.substr(0, match.get_start())
        var is_mcm := bool(line_contexts.get(line_index + 1, false)) or _infer_gd_is_mcm_context(prefix)
        var property_name := _infer_gd_property_name(prefix)
        if is_mcm:
            any_mcm = true
        if not property_name.is_empty() or is_mcm:
            has_display = true
            continue
        # Usage has no recognized display context. For const arrays this disqualifies
        # the whole array (matches the strict extractor behavior for `const`). For
        # `var` arrays we tolerate non-display usages as long as at least one display
        # usage exists — matching Python's has_display_array_usage() semantics.
        if const_only:
            all_safe = false
            break

    return {
        "safe": has_display and all_safe,
        "is_mcm": any_mcm
    }


func _localize_gd_array_literals(block: String, relative_path: String, pack: Dictionary, is_mcm: bool) -> String:
    var result := ""
    var i := 0
    var changed := false
    var context := _build_file_context(relative_path, pack, "text", is_mcm)

    while i < block.length():
        var ch := block[i]
        if ch == "\"" or ch == "'":
            var parse_result := _scan_string_literal(block, i, ch)
            if parse_result.is_empty():
                result += ch
                i += 1
                continue

            var literal := String(parse_result.get("value", ""))
            var translated := _translate_pack_text(literal, context, pack)
            result += ch + _escape_string_literal(translated, ch) + ch
            if translated != literal:
                changed = true
            i = int(parse_result.get("end", i + 1))
            continue

        result += ch
        i += 1

    if not changed:
        return block
    return result


# Returns a single unit of indentation matching the host GDScript file — either
# "\t" for tab-indented files or N spaces for space-indented files. GDScript
# requires consistent indentation across a file, so code injectors consult this
# before emitting new lines to avoid "Used tab character for indentation instead
# of space" (or vice versa) parse errors.
func _detect_gd_indent_unit(text: String) -> String:
    var min_spaces := -1
    for raw_line in text.split("\n"):
        if raw_line.is_empty():
            continue
        var first := raw_line[0]
        if first == "\t":
            return "\t"
        if first != " ":
            continue
        var n := 0
        while n < raw_line.length() and raw_line[n] == " ":
            n += 1
        if n == raw_line.length():
            continue
        if min_spaces < 0 or n < min_spaces:
            min_spaces = n
    if min_spaces > 0:
        return " ".repeat(min_spaces)
    return "\t"


func _localize_gd_formatted_item_names(text: String, relative_path: String, pack: Dictionary) -> String:
    if text.find("DEFAULT_ITEM_USES") < 0 or text.find("func _format_item_name(item_key: String) -> String:") < 0:
        return text
    if text.find("return item_key.replace(\"_\", \" \")") < 0 and text.find("return item_key.replace('_', ' ')") < 0:
        return text

    var display_names := _collect_default_item_use_display_names(text)
    if display_names.is_empty():
        return text

    var translations := {}
    var context := _build_file_context(relative_path, pack, "text", true)
    for display_name_variant in display_names:
        var display_name := String(display_name_variant)
        var translated := _translate_pack_text_relaxed(display_name, context, pack)
        if translated != display_name:
            translations[display_name] = translated
    if translations.is_empty():
        return text

    var regex := RegEx.new()
    regex.compile("(?ms)func\\s+_format_item_name\\(item_key:\\s*String\\)\\s*->\\s*String:\\s*\\n([ \\t]*)return\\s+item_key\\.replace\\([\"']_[\"']\\s*,\\s*[\"'] [\"']\\)")
    var match := regex.search(text)
    if match == null:
        return text
    var indent_unit := _detect_gd_indent_unit(text)
    var body_indent := match.get_string(1)
    if body_indent.is_empty():
        body_indent = indent_unit
    var inner_indent := body_indent + indent_unit

    var replacement := "func _format_item_name(item_key: String) -> String:\n"
    replacement += body_indent + "var display_name = item_key.replace(\"_\", \" \")\n"
    replacement += body_indent + "var translated_names = {\n"
    var keys := translations.keys()
    keys.sort()
    for key_variant in keys:
        var key := String(key_variant)
        var value := String(translations[key])
        replacement += inner_indent + "\"%s\": \"%s\",\n" % [_escape_string_literal(key, "\""), _escape_string_literal(value, "\"")]
    replacement += body_indent + "}\n"
    replacement += body_indent + "if translated_names.has(display_name):\n"
    replacement += inner_indent + "return String(translated_names[display_name])\n"
    replacement += body_indent + "return display_name"

    return text.substr(0, match.get_start()) + replacement + text.substr(match.get_end())


func _collect_default_item_use_display_names(text: String) -> Array[String]:
    var regex := RegEx.new()
    regex.compile("(?ms)const\\s+DEFAULT_ITEM_USES\\s*(?::=|=)\\s*\\{(.*?)\\}")
    var match := regex.search(text)
    if match == null:
        return []

    var block := match.get_string(1)
    var key_regex := RegEx.new()
    key_regex.compile("[\"']([^\"']+)[\"']\\s*:")
    var names: Array[String] = []
    for key_match in key_regex.search_all(block):
        var raw_key := String(key_match.get_string(1)).strip_edges()
        if raw_key.is_empty():
            continue
        var display_name := raw_key.replace("_", " ")
        if not names.has(display_name):
            names.append(display_name)
    return names


func _localize_trader_display_names(text: String, relative_path: String, pack: Dictionary) -> String:
    if not relative_path.ends_with("TraderImprovements/Config.gd"):
        return text
    if text.find("var trader_display_name") >= 0:
        return text

    var context := _build_file_context(relative_path, pack, "text", true)
    var translations := {}
    for trader_name in ["Generalist", "Doctor", "Gunsmith"]:
        var translated := _translate_pack_text_relaxed(trader_name, context, pack)
        if translated != trader_name:
            translations[trader_name] = translated
    if translations.is_empty():
        return text

    var regex := RegEx.new()
    regex.compile("(?m)^(\\s*)var\\s+trader_name\\s*=\\s*TRADERS\\[t\\]\\s*$")
    var match := regex.search(text)
    if match == null:
        return text

    var indent_unit := _detect_gd_indent_unit(text)
    var indent := match.get_string(1)
    var replacement := indent + "var trader_name = TRADERS[t]\n"
    replacement += indent + "var trader_display_name = trader_name\n"
    replacement += indent + "match trader_name:\n"
    var keys := translations.keys()
    keys.sort()
    for key_variant in keys:
        var key := String(key_variant)
        var value := String(translations[key])
        replacement += indent + indent_unit + "\"%s\":\n" % _escape_string_literal(key, "\"")
        replacement += indent + indent_unit + indent_unit + "trader_display_name = \"%s\"\n" % _escape_string_literal(value, "\"")

    var output := text.substr(0, match.get_start()) + replacement + text.substr(match.get_end())
    output = output.replace("\"name\" = trader_name +", "\"name\" = trader_display_name +")
    output = output.replace("\"tooltip\" = \"Rep needed for \" + trader_name +", "\"tooltip\" = \"Rep needed for \" + trader_display_name +")
    return output


func _scan_string_literal(text: String, start_index: int, delimiter: String) -> Dictionary:
    var i := start_index + 1
    var escaped := false
    while i < text.length():
        var ch := text[i]
        if escaped:
            escaped = false
            i += 1
            continue
        if ch == "\\":
            escaped = true
            i += 1
            continue
        if ch == delimiter:
            return {
                "value": text.substr(start_index + 1, i - start_index - 1),
                "end": i + 1
            }
        i += 1
    return {}


func _is_gd_indexer_key(prefix: String, suffix: String) -> bool:
    var trimmed_prefix := prefix.strip_edges(false, true)
    if trimmed_prefix.ends_with("["):
        return true

    var lowered := trimmed_prefix.to_lower()
    if lowered.ends_with(".get(") or lowered.ends_with("get("):
        return true
    if lowered.ends_with(".has(") or lowered.ends_with("has("):
        return true
    if lowered.ends_with(".get_value(") or lowered.ends_with("get_value("):
        return true

    # Previously this function also returned true when `suffix` began with `]`,
    # to catch expression-indexer patterns like `dict[expr + "literal"]`. That
    # heuristic had a false positive: the LAST element of a multi-line array
    # literal (no trailing comma) also has `]` as its suffix, which caused those
    # literals to be incorrectly classified as indexer keys and skipped from
    # translation. A scan of all installed mods finds zero real expression-indexer
    # cases, so we drop that check and rely on the explicit `trimmed_prefix.ends_with("[")`
    # test above, which unambiguously catches the common `dict["key"]` shape.
    return false


func _is_gd_dict_key(suffix: String) -> bool:
    var trimmed_suffix := suffix.strip_edges(true, false)
    if trimmed_suffix.begins_with(":"):
        return true
    if trimmed_suffix.begins_with("=") and not trimmed_suffix.begins_with("==") and not trimmed_suffix.begins_with("=~") and not trimmed_suffix.begins_with("=>"):
        return true
    return false


func _is_non_display_gd_prefix(prefix: String) -> bool:
    var lowered := prefix.strip_edges(false, true).to_lower()
    var stripped := lowered.strip_edges(true, false)
    if stripped.begins_with("const "):
        # Exception: when IDENT in `const IDENT := "..."` is used at a known
        # display argument position (friendlyName/description) in a
        # RegisterConfiguration-like call, the declaration IS effectively the
        # display literal, so don't skip it.
        var ident := _extract_const_identifier_from_prefix(prefix)
        if ident.is_empty() or not _current_gd_const_properties.has(ident):
            return true
    return lowered.ends_with(".file =") \
        or lowered.ends_with("file =") \
        or lowered.ends_with(".inventory =") \
        or lowered.ends_with("inventory =") \
        or lowered.ends_with(".equipment =") \
        or lowered.ends_with("equipment =") \
        or lowered.ends_with(".rotated =") \
        or lowered.ends_with("rotated =") \
        or lowered.ends_with(".section =") \
        or lowered.ends_with("section =") \
        or lowered.ends_with(".key =") \
        or lowered.ends_with("key =") \
        or lowered.ends_with(".value =") \
        or lowered.ends_with("value =") \
        or lowered.ends_with(".type =") \
        or lowered.ends_with("type =") \
        or lowered.ends_with(".path =") \
        or lowered.ends_with("path =") \
        or lowered.ends_with(".nodepath =") \
        or lowered.ends_with("nodepath =")


func _is_ascii_alpha(text: String) -> bool:
    if text.is_empty():
        return false
    for i in range(text.length()):
        var code := text.unicode_at(i)
        var is_upper := code >= 65 and code <= 90
        var is_lower := code >= 97 and code <= 122
        if not is_upper and not is_lower:
            return false
    return true


func _is_identifier_only(text: String) -> bool:
    if text.is_empty():
        return false
    var first := text.unicode_at(0)
    var valid_first := (first >= 65 and first <= 90) or (first >= 97 and first <= 122) or first == 95
    if not valid_first:
        return false
    for i in range(1, text.length()):
        var code := text.unicode_at(i)
        var is_letter := (code >= 65 and code <= 90) or (code >= 97 and code <= 122)
        var is_digit := code >= 48 and code <= 57
        if not is_letter and not is_digit and code != 95:
            return false
    return true


func _is_numeric_or_symbolic(text: String) -> bool:
    if text.is_empty():
        return false
    var has_allowed := false
    for i in range(text.length()):
        var ch := text[i]
        if ch.is_valid_int():
            has_allowed = true
            continue
        if " \t.,+-/()[]{}:;%'".contains(ch):
            continue
        return false
    return has_allowed


func _should_skip_gd_literal(literal: String, prefix: String, property_name: String, is_mcm: bool, require_display: bool = true) -> bool:
    # When require_display=true (default, strict mode): literals without a recognized
    # display property (.text=, tooltip dict, etc.) are skipped. This is the safe default
    # for the main per-file walk.
    #
    # When require_display=false: property emptiness alone does NOT disqualify the literal.
    # All other hard-safety checks (paths, identifiers, .file=/.name= assignments, etc.)
    # still apply. Used as a fallback so that pre-extracted pack fragments appearing in
    # expression contexts (e.g. `"+" + str(x) + " Max HP"`) can still be translated when
    # the pack explicitly contains that `from` text.
    var text := literal.strip_edges()
    var stripped_prefix := prefix.strip_edges(false, true)
    var lowered_prefix := stripped_prefix.to_lower()
    if text.is_empty():
        return true
    if literal.begins_with("res://") or literal.begins_with("user://"):
        return true
    if literal.ends_with(".gd") or literal.ends_with(".cfg") or literal.ends_with(".tscn") or literal.ends_with(".tres") or literal.ends_with(".mp3"):
        return true
    if literal.begins_with("/") or literal.begins_with("./") or literal.begins_with("../"):
        return true
    if _is_numeric_or_symbolic(text):
        return true
    if (text.contains("%s") or text.contains("%d") or text.contains("%f") or text.contains("%i")) \
        and not _has_translatable_content_around_format(text):
        return true
    if text.contains("\n") and not text.is_valid_identifier():
        return true
    if text.length() <= 2 and _is_ascii_alpha(text):
        return true
    if text.length() <= 2 and not text.is_valid_identifier() and not text.is_valid_int():
        return true
    if stripped_prefix.ends_with(".name =") or stripped_prefix.ends_with("name ="):
        return true
    if stripped_prefix.ends_with(".id =") or stripped_prefix.ends_with("id ="):
        return true
    if stripped_prefix.ends_with("class_name"):
        return true
    if lowered_prefix.ends_with("get_node(") or lowered_prefix.ends_with("has_node("):
        return true
    if lowered_prefix.ends_with("load(") or lowered_prefix.ends_with("preload("):
        return true
    if _is_non_display_gd_prefix(prefix):
        return true
    if require_display and property_name.is_empty():
        return true
    if property_name == "config_key" or property_name == "config_type":
        return true
    if not is_mcm and property_name == "name":
        return true
    if _is_identifier_only(text) and not is_mcm and property_name != "text" and property_name != "title" and property_name != "label" and property_name != "category" and property_name != "rename" and property_name != "hover" and property_name != "message" and property_name != "phrase":
        return true
    return false


func _has_translatable_content_around_format(text: String) -> bool:
    # Strip `%s`, `%d`, `%05d`, `%-10s`, etc. and check if at least two consecutive
    # letters remain. Used to decide whether a format string like
    # "Enemies Killed: %s/%s" should be extracted/translated (yes) vs a pure
    # placeholder like "%d/%d" (no).
    var stripped := _fmt_placeholder_re.sub(text, "", true)
    return _alpha_run_re.search(stripped) != null


func _build_gd_line_contexts(text: String) -> Dictionary:
    var contexts := {}
    var in_mcm_set_value := false
    var in_mcm_register := false

    var line_number := 1
    for raw_line in text.split("\n", true):
        if raw_line.strip_edges(true, false).begins_with("#"):
            contexts[line_number] = false
            line_number += 1
            continue

        var line := raw_line.strip_edges()
        var lowered := raw_line.to_lower()

        if _is_mcm_set_value_line(lowered):
            in_mcm_set_value = true
        if lowered.contains("registerconfiguration(") \
            or lowered.contains("registerconfigruation(") \
            or lowered.contains("_call_mcm_register_configuration("):
            in_mcm_register = true

        contexts[line_number] = in_mcm_set_value or in_mcm_register

        if in_mcm_set_value and line.ends_with("})"):
            in_mcm_set_value = false
        if in_mcm_register and line == ")":
            in_mcm_register = false

        line_number += 1

    return contexts


func _is_mcm_set_value_line(lowered_line: String) -> bool:
    return lowered_line.contains(".set_value(") and lowered_line.contains("{")


func _infer_register_mcm_property(prefix: String) -> String:
    var lowered := prefix.to_lower()
    var markers := ["registerconfiguration(", "registerconfigruation(", "_call_mcm_register_configuration(", ".call("]
    var marker_pos := -1
    var marker_text := ""
    for marker in markers:
        var pos := lowered.rfind(marker)
        if pos > marker_pos:
            marker_pos = pos
            marker_text = marker
    if marker_pos < 0:
        return ""

    var args_prefix := prefix.substr(marker_pos + marker_text.length())
    if marker_text == ".call(":
        if not args_prefix.strip_edges(true, false).begins_with("register_method"):
            return ""
        var call_commas := _count_top_level_commas(args_prefix)
        if call_commas == 2:
            return "friendlyName"
        if call_commas == 4:
            return "description"
        return ""

    var comma_count := args_prefix.count(",")
    if marker_text == "_call_mcm_register_configuration(":
        if comma_count == 0:
            return "friendlyName"
        if comma_count == 1:
            return "description"
        return ""

    if comma_count == 1:
        return "friendlyName"
    if comma_count == 3:
        return "description"
    return ""


func _count_top_level_commas(text: String) -> int:
    var depth_paren := 0
    var depth_bracket := 0
    var depth_brace := 0
    var i := 0
    var count := 0
    while i < text.length():
        var ch := text[i]
        if ch == "\"" or ch == "'":
            var parse_result := _scan_string_literal(text, i, ch)
            if not parse_result.is_empty():
                i = int(parse_result.get("end", i + 1))
                continue
        elif ch == "(":
            depth_paren += 1
        elif ch == ")" and depth_paren > 0:
            depth_paren -= 1
        elif ch == "[":
            depth_bracket += 1
        elif ch == "]" and depth_bracket > 0:
            depth_bracket -= 1
        elif ch == "{":
            depth_brace += 1
        elif ch == "}" and depth_brace > 0:
            depth_brace -= 1
        elif ch == "," and depth_paren == 0 and depth_bracket == 0 and depth_brace == 0:
            count += 1
        i += 1
    return count


func _first_string_literal(text: String) -> String:
    var i := 0
    while i < text.length():
        var ch := text[i]
        if ch == "\"" or ch == "'":
            var parse_result := _scan_string_literal(text, i, ch)
            if not parse_result.is_empty():
                return String(parse_result.get("value", ""))
        i += 1
    return ""


func _infer_set_value_argument_property(prefix: String) -> String:
    var lowered := prefix.to_lower()
    for marker in [".set_value(", ".get_value("]:
        var marker_pos := lowered.rfind(marker)
        if marker_pos < 0:
            continue

        var args_prefix := prefix.substr(marker_pos + marker.length())
        var comma_count := _count_top_level_commas(args_prefix)
        if comma_count != 1:
            continue

        if marker == ".get_value(":
            return "config_key"

        var first_arg := _first_string_literal(args_prefix).to_lower()
        if first_arg == "category":
            return "category"
        return "config_key"
    return ""


func _infer_gd_property_name(prefix: String) -> String:
    var lowered := prefix.to_lower()
    for pair in PROPERTY_INFERENCE_PATTERNS:
        if lowered.contains(String(pair[0])):
            return String(pair[1])
    var set_value_property := _infer_set_value_argument_property(prefix)
    if not set_value_property.is_empty():
        return set_value_property
    return _infer_register_mcm_property(prefix)


func _infer_gd_is_mcm_context(prefix: String) -> bool:
    var lowered := prefix.to_lower()
    return lowered.contains("mcm_") \
        or _is_mcm_set_value_line(lowered) \
        or lowered.contains("registerconfiguration(") \
        or lowered.contains("registerconfigruation(") \
        or lowered.contains("checkconfigurationhasupdated(") \
        or lowered.contains("checkconfigruationhasupdated(")


func _escape_string_literal(text: String, delimiter: String) -> String:
    # `text` comes from _scan_string_literal in GDScript source form: existing escape
    # sequences (\n, \t, \\, \") are preserved verbatim. We MUST NOT blindly re-escape
    # backslashes, or the source `"foo\n"` round-trips to `"foo\\n"`, which Godot then
    # parses as the literal string `foo\n` instead of "foo" + newline.
    #
    # What we do need:
    #   * Any UNESCAPED delimiter character inside `text` must be escaped so it doesn't
    #     prematurely terminate the string on the next parse.
    #   * Raw control characters (newline, tab, carriage return) that happen to land in
    #     a pack translation must be promoted to their escape-sequence form, otherwise
    #     the emitted GDScript would be a syntax error.
    var result := ""
    var escaped := false
    for i in range(text.length()):
        var ch := text[i]
        if escaped:
            # The previous backslash was already emitted; whatever follows is part of
            # an escape sequence and must be preserved verbatim.
            result += ch
            escaped = false
            continue
        if ch == "\\":
            result += ch
            escaped = true
            continue
        if ch == delimiter:
            result += "\\"
            result += ch
            continue
        if ch == "\n":
            result += "\\n"
            continue
        if ch == "\r":
            result += "\\r"
            continue
        if ch == "\t":
            result += "\\t"
            continue
        result += ch
    return result


func _localize_resource_text(text: String, relative_path: String, pack: Dictionary) -> String:
    var lines := text.split("\n", false)
    var changed := false
    for i in range(lines.size()):
        var line := lines[i]
        var equal_index := line.find("=")
        if equal_index < 0:
            continue

        var key := line.substr(0, equal_index).strip_edges()
        if not RESOURCE_DISPLAY_PROPERTIES.has(key):
            continue

        var value := line.substr(equal_index + 1).strip_edges()
        if not value.begins_with("\"") or value.length() < 2:
            continue
        var parse_result := _scan_string_literal(value, 0, "\"")
        if parse_result.is_empty():
            continue

        var literal := String(parse_result.get("value", ""))
        var context := _build_file_context(relative_path, pack, key, false)
        var translated := _translate_pack_text(literal, context, pack)
        if translated == literal:
            continue

        var escaped := _escape_string_literal(translated, "\"")
        var suffix := value.substr(int(parse_result.get("end", 1)))
        lines[i] = "%s = \"%s\"%s" % [key, escaped, suffix]
        changed = true
    if not changed:
        return text
    return "\n".join(lines)


func _localize_cfg_text(text: String, relative_path: String, pack: Dictionary) -> String:
    var lines := text.split("\n", false)
    var changed := false
    for i in range(lines.size()):
        var line := lines[i]
        var equal_index := line.find("=")
        if equal_index < 0:
            continue

        var key := line.substr(0, equal_index).strip_edges()
        if not CONFIG_DISPLAY_KEYS.has(key):
            continue

        var value := line.substr(equal_index + 1).strip_edges()
        if not value.begins_with("\"") or value.length() < 2:
            continue
        var parse_result := _scan_string_literal(value, 0, "\"")
        if parse_result.is_empty():
            continue

        var literal := String(parse_result.get("value", ""))
        var context := _build_file_context(relative_path, pack, key, true)
        var translated := _translate_pack_text(literal, context, pack)
        if translated == literal:
            continue

        var escaped := _escape_string_literal(translated, "\"")
        var suffix := value.substr(int(parse_result.get("end", 1)))
        lines[i] = "%s = \"%s\"%s" % [key, escaped, suffix]
        changed = true
    if not changed:
        return text
    return "\n".join(lines)


func _pack_dir_to_vmz(source_dir: String, output_path: String) -> int:
    # Pack to a sibling .rtvtmp first so a crash mid-write never leaves a
    # corrupted .vmz at output_path that the next launch would mistake for a
    # finished build.
    var tmp_path := output_path + TMP_SUFFIX
    _remove_file_if_exists(tmp_path)

    var packer := ZIPPacker.new()
    var open_error := packer.open(tmp_path)
    if open_error != OK:
        _remove_file_if_exists(tmp_path)
        return open_error

    var root_length := source_dir.length() + 1
    var pack_error := _pack_directory_recursive(source_dir, root_length, packer)
    packer.close()
    if pack_error != OK:
        _remove_file_if_exists(tmp_path)
        return pack_error

    _remove_file_if_exists(output_path)
    var rename_error := DirAccess.rename_absolute(tmp_path, output_path)
    if rename_error != OK:
        _remove_file_if_exists(tmp_path)
        return rename_error
    return OK


func _pack_directory_recursive(dir_path: String, root_length: int, packer: ZIPPacker) -> int:
    var dir := DirAccess.open(dir_path)
    if dir == null:
        return ERR_CANT_OPEN

    dir.list_dir_begin()
    while true:
        var entry_name := dir.get_next()
        if entry_name.is_empty():
            break
        if entry_name == "." or entry_name == "..":
            continue

        var entry_path := dir_path.path_join(entry_name)
        if dir.current_is_dir():
            var child_error := _pack_directory_recursive(entry_path, root_length, packer)
            if child_error != OK:
                dir.list_dir_end()
                return child_error
            continue

        var relative_path := entry_path.substr(root_length).replace("\\", "/")
        var file := FileAccess.open(entry_path, FileAccess.READ)
        if file == null:
            dir.list_dir_end()
            return ERR_CANT_OPEN
        var bytes := file.get_buffer(file.get_length())
        file.close()

        var start_error := packer.start_file(relative_path)
        if start_error != OK:
            dir.list_dir_end()
            return start_error
        packer.write_file(bytes)
        packer.close_file()
    dir.list_dir_end()
    return OK


func _copy_file(source_path: String, target_path: String) -> bool:
    var source := FileAccess.open(source_path, FileAccess.READ)
    if source == null:
        return false
    var bytes := source.get_buffer(source.get_length())
    source.close()

    _ensure_parent_directory(target_path)
    var target := FileAccess.open(target_path, FileAccess.WRITE)
    if target == null:
        return false
    target.store_buffer(bytes)
    target.close()
    return true


func _deploy_vmz_file(source_path: String, deploy_path: String) -> bool:
    # Write-then-rename: stage a copy at <deploy>.rtvtmp, swap the old file
    # aside to <deploy>.rtvactive, rename the staging file into place, then
    # remove the swap. If any step fails we fully roll back so the user is
    # never left without a valid .vmz.
    var tmp_path := deploy_path + TMP_SUFFIX
    var staged_old := deploy_path + ACTIVE_SWAP_SUFFIX
    _remove_file_if_exists(tmp_path)
    _remove_file_if_exists(staged_old)

    if not _copy_file(source_path, tmp_path):
        _remove_file_if_exists(tmp_path)
        _log("WARN", "Deploy failed: could not stage %s" % tmp_path)
        return false

    if FileAccess.file_exists(deploy_path):
        if DirAccess.rename_absolute(deploy_path, staged_old) != OK:
            _remove_file_if_exists(tmp_path)
            _log("WARN", "Deploy failed: could not move existing %s aside" % deploy_path)
            return false

    if DirAccess.rename_absolute(tmp_path, deploy_path) != OK:
        # Rollback: restore the original if we moved it aside.
        _remove_file_if_exists(tmp_path)
        if FileAccess.file_exists(staged_old):
            DirAccess.rename_absolute(staged_old, deploy_path)
        _log("WARN", "Deploy failed: could not promote staging file to %s" % deploy_path)
        return false

    _remove_file_if_exists(staged_old)
    return true


func _restore_vmz_file(backup_path: String, deploy_path: String) -> bool:
    var staged_old := deploy_path + ACTIVE_SWAP_SUFFIX
    _remove_file_if_exists(staged_old)

    if FileAccess.file_exists(deploy_path):
        if DirAccess.rename_absolute(deploy_path, staged_old) != OK:
            return false

    if DirAccess.rename_absolute(backup_path, deploy_path) == OK:
        _remove_file_if_exists(staged_old)
        return true

    if FileAccess.file_exists(staged_old):
        DirAccess.rename_absolute(staged_old, deploy_path)
    return false


func _ensure_parent_directory(path: String) -> void:
    var base_dir := path.get_base_dir()
    if base_dir.is_empty():
        return
    DirAccess.make_dir_recursive_absolute(base_dir)


func _remove_file_if_exists(path: String) -> void:
    if path.is_empty() or not FileAccess.file_exists(path):
        return
    DirAccess.remove_absolute(path)


func _remove_dir_recursive(path: String) -> void:
    if path.is_empty():
        return
    var dir := DirAccess.open(path)
    if dir == null:
        return

    dir.list_dir_begin()
    while true:
        var entry_name := dir.get_next()
        if entry_name.is_empty():
            break
        if entry_name == "." or entry_name == "..":
            continue
        var entry_path := path.path_join(entry_name)
        if dir.current_is_dir():
            _remove_dir_recursive(entry_path)
        else:
            DirAccess.remove_absolute(entry_path)
    dir.list_dir_end()
    DirAccess.remove_absolute(path)
