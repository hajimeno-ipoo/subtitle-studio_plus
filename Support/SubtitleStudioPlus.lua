-- SubtitleStudioPlus.lua
-- Launcher only. The real bridge lives under ResolveBridgeResources/modules.

---@diagnostic disable: undefined-global
local resolve = resolve

local DEFAULT_APP_PATH = "/Applications/SubtitleStudioPlus.app"
local DEFAULT_RESOURCES_DIR = "ResolveBridgeResources"

local function log(message)
    print("[SubtitleStudioPlus] " .. message)
end

local function join_path(dir, filename)
    local sep = package.config:sub(1, 1)
    if dir:sub(-1) == sep then
        return dir .. filename
    end
    return dir .. sep .. filename
end

local function resolve_resources_root(app_path)
    local override = os.getenv("SUBTITLE_STUDIO_RESOLVE_BRIDGE_ROOT")
    if override and override ~= "" then
        return override
    end

    return join_path(app_path, "Contents/Resources/" .. DEFAULT_RESOURCES_DIR)
end

local function ensure_package_path(modules_path)
    package.path = package.path .. ";" .. join_path(modules_path, "?.lua")
end

local function main()
    if resolve == nil then
        log("Resolve global unavailable")
        return
    end

    local app_path = os.getenv("SUBTITLE_STUDIO_APP_PATH") or DEFAULT_APP_PATH
    local resources_root = resolve_resources_root(app_path)
    if not resources_root then
        log("Bridge resources path could not be resolved")
        return
    end

    local modules_path = join_path(resources_root, "modules")
    ensure_package_path(modules_path)

    local ok, core_or_err = pcall(require, "resolve_bridge_core")
    if not ok then
        log("Failed to load resolve_bridge_core: " .. tostring(core_or_err))
        return
    end

    local dev_mode = os.getenv("SUBTITLE_STUDIO_DEV_MODE") == "1"

    log("Starting Resolve bridge")
    core_or_err:Init(app_path, resources_root, dev_mode)
end

main()
