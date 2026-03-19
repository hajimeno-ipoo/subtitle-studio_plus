---@diagnostic disable: undefined-global
local ffi = ffi
local resolve = resolve

local socket = require("ljsocket")
local json = require("dkjson")

local PORT = 56002
local DEFAULT_TEMPLATE_NAME = "Default Template"
local DEFAULT_APP_PATH = "/Applications/SubtitleStudioPlus.app"
local DEFAULT_SERVER_HOST = "127.0.0.1"
local DEFAULT_SERVER_URL = "http://127.0.0.1:56002"
local DEFAULT_SUBTITLE_FONT = "Hiragino Sans"
local DEFAULT_SUBTITLE_STYLE = "W6"

local assets_path = nil
local user_assets_path = nil
local resources_path = nil
local main_app = nil
local command_open = nil
local current_session_id = nil

local projectManager = nil
local project = nil
local mediaPool = nil

local DEV_MODE = false

local titleStrings = {
    "Título – Fusion",
    "Título Fusion",
    "Generator",
    "Fusion Title",
    "Titre Fusion",
    "Титры на стр. Fusion",
    "Fusion Titel",
    "Titolo Fusion",
    "Fusionタイトル",
    "Fusion标题",
    "퓨전 타이틀",
    "Tiêu đề Fusion",
    "Fusion Titles",
}

local titleSet = {}
for _, title in ipairs(titleStrings) do
    titleSet[title] = true
end

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

local function shell_quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function trim(value)
    if value == nil then
        return nil
    end

    value = tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
    if value == "" then
        return nil
    end

    return value
end

local function new_session_id()
    local suffix = tostring({}):match("0x(%x+)")
    local seed = os.time()
    if suffix then
        seed = seed + tonumber(suffix, 16)
    end
    math.randomseed(seed)
    math.random()
    math.random()
    return string.format("resolve-%s-%04d", os.date("%Y%m%d-%H%M%S"), math.random(0, 9999))
end

local function detect_os()
    if ffi and ffi.os then
        return ffi.os
    end
    return "OSX"
end

local function file_exists(path)
    local handle = io.open(path, "r")
    if handle then
        handle:close()
        return true
    end
    return false
end

local function ensure_directory(path)
    if not path then
        return false
    end

    local command = string.format("/bin/mkdir -p %s", shell_quote(path))
    local ok = os.execute(command)
    return ok == true or ok == 0
end

local function get_template_asset_path()
    if user_assets_path then
        local override_path = join_path(user_assets_path, "subtitle-template.drb")
        if file_exists(override_path) then
            return override_path
        end
    end

    if assets_path then
        return join_path(assets_path, "subtitle-template.drb")
    end

    return nil
end

local function to_number(value)
    local number = tonumber(value or "")
    if number == nil then
        return nil
    end
    return number
end

local function seconds_to_frames(seconds, frame_rate)
    return math.floor((tonumber(seconds) or 0) * frame_rate + 0.5)
end

local function frames_to_seconds(frames, frame_rate)
    return (tonumber(frames) or 0) / frame_rate
end

local function get_frame_rate(timeline)
    local frame_rate = tonumber(timeline:GetSetting("timelineFrameRate"))
    if frame_rate and frame_rate > 0 then
        return frame_rate
    end
    return 24
end

local function refresh_project_state()
    projectManager = resolve:GetProjectManager()
    project = projectManager and projectManager:GetCurrentProject() or nil
    mediaPool = project and project:GetMediaPool() or nil
end

local function walk_media_pool(folder, on_clip)
    if not folder then
        return
    end

    local subfolders = folder:GetSubFolderList() or {}
    for _, subfolder in ipairs(subfolders) do
        local stop = walk_media_pool(subfolder, on_clip)
        if stop then
            return true
        end
    end

    local clips = folder:GetClipList() or {}
    for _, clip in ipairs(clips) do
        local stop = on_clip(clip)
        if stop then
            return true
        end
    end

    return false
end

local function is_title_clip(title)
    return titleSet[title] == true
end

local function parse_json(text)
    local data, _, err = json.decode(text, 1, nil)
    if err then
        return nil, err
    end
    return data
end

local function encode_json(value)
    local encoded, err = json.encode(value)
    if encoded then
        return encoded
    end

    return string.format('{"error":true,"message":%q}', err or "json encoding failed")
end

local function create_response(body)
    return table.concat({
        "HTTP/1.1 200 OK\r\n",
        "Server: ljsocket/0.1\r\n",
        "Content-Type: application/json\r\n",
        "Content-Length: ",
        tostring(#body),
        "\r\nConnection: close\r\n\r\n",
        body,
    })
end

local function current_project_name()
    local current = projectManager and projectManager:GetCurrentProject() or nil
    if not current then
        return nil
    end

    return current:GetName()
end

local function request_is_complete(request)
    local separator_start, separator_end = string.find(request, "\r\n\r\n", 1, true)
    if not separator_end then
        return false
    end

    local headers = string.sub(request, 1, separator_start - 1)
    local content_length = tonumber(string.match(headers, "[Cc]ontent%-[Ll]ength:%s*(%d+)"))
    if not content_length then
        return true
    end

    local body_start = separator_end + 1
    local current_length = #request - (body_start - 1)
    return current_length >= content_length
end

local function current_timeline_name()
    local current = projectManager and projectManager:GetCurrentProject() or nil
    if not current then
        return nil
    end

    local timeline = current:GetCurrentTimeline()
    if not timeline then
        return nil
    end

    return timeline:GetName()
end

local function get_template_item(folder, template_name)
    if not folder then
        return nil, nil
    end

    local clips = folder:GetClipList() or {}
    for _, clip in ipairs(clips) do
        local properties = clip:GetClipProperty() or {}
        if properties["Clip Name"] == template_name then
            return clip, folder
        end
    end

    local subfolders = folder:GetSubFolderList() or {}
    for _, subfolder in ipairs(subfolders) do
        local clip, owner_folder = get_template_item(subfolder, template_name)
        if clip then
            return clip, owner_folder
        end
    end

    return nil, nil
end

local function sync_template_asset(folder)
    if not folder or not user_assets_path then
        return
    end

    if not ensure_directory(user_assets_path) then
        log("Unable to prepare user template folder: " .. tostring(user_assets_path))
        return
    end

    local target_path = join_path(user_assets_path, "subtitle-template.drb")
    local ok, exported = pcall(function()
        return folder:Export(target_path)
    end)

    if ok and exported then
        log("Synced Default Template to " .. target_path)
    end
end

local function import_default_template_if_missing()
    if not mediaPool then
        return
    end

    local template_path = get_template_asset_path()
    if not template_path or not file_exists(template_path) then
        return
    end

    pcall(function()
        mediaPool:ImportFolderFromFile(template_path)
    end)
end

local function get_templates()
    refresh_project_state()

    local templates = {}
    local has_default = false
    local root = mediaPool and mediaPool:GetRootFolder() or nil

    if root then
        walk_media_pool(root, function(clip)
            local properties = clip:GetClipProperty() or {}
            local clip_type = properties["Type"]
            local clip_name = properties["Clip Name"]
            if is_title_clip(clip_type) and clip_name then
                templates[#templates + 1] = {
                    label = clip_name,
                    value = clip_name,
                }
                if clip_name == DEFAULT_TEMPLATE_NAME then
                    has_default = true
                end
            end
        end)
    end

    if not has_default then
        import_default_template_if_missing()
        refresh_project_state()
        templates = {}
        root = mediaPool and mediaPool:GetRootFolder() or nil
        if root then
            walk_media_pool(root, function(clip)
                local properties = clip:GetClipProperty() or {}
                local clip_type = properties["Type"]
                local clip_name = properties["Clip Name"]
                if is_title_clip(clip_type) and clip_name then
                    templates[#templates + 1] = {
                        label = clip_name,
                        value = clip_name,
                    }
                end
            end)
        end
    end

    return templates
end

local function get_video_tracks(timeline)
    local tracks = {
        {
            value = "0",
            label = "Add to New Track",
        },
    }

    local track_count = timeline:GetTrackCount("video") or 0
    for index = 1, track_count do
        tracks[#tracks + 1] = {
            value = tostring(index),
            label = timeline:GetTrackName("video", index),
        }
    end

    return tracks
end

local function get_audio_tracks(timeline)
    local tracks = {}
    local track_count = timeline:GetTrackCount("audio") or 0
    for index = 1, track_count do
        tracks[#tracks + 1] = {
            value = tostring(index),
            label = timeline:GetTrackName("audio", index),
        }
    end
    return tracks
end

local function get_timeline_info()
    refresh_project_state()

    local timeline = project and project:GetCurrentTimeline() or nil
    if not timeline then
        return {
            sessionID = current_session_id,
            projectName = current_project_name(),
            name = "",
            timelineId = "",
            timelineStart = 0,
            outputTracks = {},
            inputTracks = {},
            templates = get_templates(),
        }
    end

    local frame_rate = get_frame_rate(timeline)
    return {
        sessionID = current_session_id,
        projectName = current_project_name(),
        name = timeline:GetName(),
        timelineId = timeline:GetUniqueId(),
        timelineStart = frames_to_seconds(timeline:GetStartFrame(), frame_rate),
        outputTracks = get_video_tracks(timeline),
        inputTracks = get_audio_tracks(timeline),
        templates = get_templates(),
    }
end

local function timeline_has_overlap(timeline, track_index, start_frame, end_frame)
    local items = timeline:GetItemListInTrack("video", track_index) or {}
    if #items == 0 then
        return false
    end

    for _, item in ipairs(items) do
        local item_start = item:GetStart()
        local item_end = item:GetEnd()
        if not (item_end <= start_frame or item_start >= end_frame) then
            return true
        end
        if item_start > end_frame then
            break
        end
    end

    return false
end

local function sanitize_track_index(timeline, requested_index, start_frame, end_frame)
    local track_index = tonumber(requested_index) or 1
    local track_count = timeline:GetTrackCount("video") or 0

    if track_index < 1 or track_index > track_count or timeline_has_overlap(timeline, track_index, start_frame, end_frame) then
        timeline:AddTrack("video")
        return timeline:GetTrackCount("video") or 1
    end

    return track_index
end

local function ensure_template_item(template_name)
    local root = mediaPool and mediaPool:GetRootFolder() or nil
    if not root then
        return nil, template_name
    end

    local requested_name = trim(template_name) or DEFAULT_TEMPLATE_NAME
    local template_item, template_folder = get_template_item(root, requested_name)
    if template_item then
        sync_template_asset(template_folder)
        return template_item, requested_name
    end

    if requested_name ~= DEFAULT_TEMPLATE_NAME then
        template_item, template_folder = get_template_item(root, DEFAULT_TEMPLATE_NAME)
        if template_item then
            sync_template_asset(template_folder)
            return template_item, DEFAULT_TEMPLATE_NAME
        end
    end

    import_default_template_if_missing()
    refresh_project_state()
    root = mediaPool and mediaPool:GetRootFolder() or nil

    template_item, template_folder = get_template_item(root, requested_name)
    if template_item then
        sync_template_asset(template_folder)
        return template_item, requested_name
    end

    if requested_name ~= DEFAULT_TEMPLATE_NAME then
        template_item, template_folder = get_template_item(root, DEFAULT_TEMPLATE_NAME)
        if template_item then
            sync_template_asset(template_folder)
            return template_item, DEFAULT_TEMPLATE_NAME
        end
    end

    return nil, requested_name
end

local function sorted_segments(segments)
    local copy = {}
    for _, segment in ipairs(segments) do
        copy[#copy + 1] = segment
    end

    table.sort(copy, function(left, right)
        return (tonumber(left.start) or 0) < (tonumber(right.start) or 0)
    end)

    return copy
end

local function apply_subtitle_font(tool)
    if not tool then
        return
    end

    pcall(function()
        tool:SetInput("Font", DEFAULT_SUBTITLE_FONT)
    end)

    pcall(function()
        tool:SetInput("Style", DEFAULT_SUBTITLE_STYLE)
    end)
end

local function add_subtitles(payload)
    refresh_project_state()

    if not project or not mediaPool then
        return false, "project or media pool unavailable"
    end

    local timeline = project:GetCurrentTimeline()
    if not timeline then
        return false, "timeline unavailable"
    end

    local segments = payload and payload.segments or nil
    if type(segments) ~= "table" or #segments == 0 then
        return false, "segments are missing"
    end

    resolve:OpenPage("edit")

    local frame_rate = get_frame_rate(timeline)
    local timeline_start_seconds = tonumber(payload.timelineStart)
    if timeline_start_seconds == nil then
        timeline_start_seconds = frames_to_seconds(timeline:GetStartFrame(), frame_rate)
    end
    local timeline_start_frame = seconds_to_frames(timeline_start_seconds, frame_rate)

    local ordered_segments = sorted_segments(segments)
    local first_start = tonumber(ordered_segments[1].start) or 0
    local last_end = tonumber(ordered_segments[#ordered_segments]["end"]) or first_start
    local start_frame = timeline_start_frame + seconds_to_frames(first_start, frame_rate)
    local end_frame = timeline_start_frame + seconds_to_frames(last_end, frame_rate)

    local track_index = sanitize_track_index(timeline, payload.trackIndex or 1, start_frame, end_frame)
    local template_item, resolved_template_name = ensure_template_item(payload.templateName)
    if not template_item then
        return false, "Default Template not found in media pool"
    end

    local template_frame_rate = tonumber((template_item:GetClipProperty() or {})["FPS"]) or frame_rate
    local clip_list = {}

    for _, segment in ipairs(ordered_segments) do
        local segment_start = tonumber(segment.start)
        local segment_end = tonumber(segment["end"])
        local subtitle_text = tostring(segment.text or "")

        if segment_start and segment_end and segment_end > segment_start then
            local segment_start_frame = seconds_to_frames(segment_start, frame_rate)
            local segment_end_frame = seconds_to_frames(segment_end, frame_rate)
            local clip_timeline_duration = math.max(1, segment_end_frame - segment_start_frame)
            local duration = math.max(1, math.floor((clip_timeline_duration / frame_rate) * template_frame_rate + 0.5))

            clip_list[#clip_list + 1] = {
                mediaPoolItem = template_item,
                mediaType = 1,
                startFrame = 0,
                endFrame = duration,
                recordFrame = timeline_start_frame + segment_start_frame,
                trackIndex = track_index,
            }

            segment._subtitle_text = subtitle_text
        end
    end

    if #clip_list == 0 then
        return false, "no valid subtitle segments"
    end

    local timeline_items = mediaPool:AppendToTimeline(clip_list)
    if type(timeline_items) ~= "table" or #timeline_items == 0 then
        return false, "AppendToTimeline returned no timeline items"
    end

    for index, timeline_item in ipairs(timeline_items) do
        local segment = ordered_segments[index]
        local subtitle_text = tostring(segment and segment._subtitle_text or "")

        if timeline_item:GetFusionCompCount() > 0 then
            local comp = timeline_item:GetFusionCompByIndex(1)
            if comp then
                local tool = comp:FindToolByID("TextPlus")
                if tool then
                    apply_subtitle_font(tool)
                    tool:SetInput("StyledText", subtitle_text)
                end
            end
        end
    end

    pcall(function()
        if projectManager and projectManager.SaveProject then
            projectManager:SaveProject()
        end
    end)

    return true, {
        message = "Subtitles added",
        templateName = resolved_template_name,
        trackIndex = track_index,
        added = #timeline_items,
    }
end

local function launch_app()
    local os_name = detect_os()

    if os_name == "Windows" then
        command_open = "start \"\" " .. shell_quote(main_app)
    elseif os_name == "OSX" then
        command_open = "open -a " .. shell_quote(main_app) .. " --args --resolve-server-url " .. shell_quote(DEFAULT_SERVER_URL)
    else
        command_open = shell_quote(main_app) .. " &"
    end

    log("Launching SubtitleStudioPlus.app")
    local result = os.execute(command_open)
    if result == 0 or result == true then
        return true
    end

    log("Launch command failed")
    return false
end

local function send_exit_via_socket()
    local ok = pcall(function()
        local info = assert(socket.find_first_address(DEFAULT_SERVER_HOST, PORT))
        local client = assert(socket.create(info.family, info.socket_type, info.protocol))
        assert(client:set_option("nodelay", true, "tcp"))
        client:set_blocking(true)
        assert(client:connect(info))

        local body = '{"func":"Exit"}'
        local request = string.format(
            "POST / HTTP/1.1\r\nHost: %s:%d\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s",
            DEFAULT_SERVER_HOST,
            PORT,
            #body,
            body
        )

        assert(client:send(request))
        client:close()
    end)

    if not ok then
        log("Failed to send Exit to existing bridge")
    end
end

local function read_request(client)
    local request = ""
    local idle_reads = 0
    local max_idle_reads = 10

    while idle_reads < max_idle_reads do
        local chunk, err = client:receive(1024)
        if chunk and #chunk > 0 then
            request = request .. chunk
            idle_reads = 0
            if request_is_complete(request) then
                break
            end
        elseif err == "timeout" then
            idle_reads = idle_reads + 1
            os.execute("sleep 0.05")
            if request_is_complete(request) then
                break
            end
        else
            break
        end
    end

    return request
end

local function extract_request_body(request)
    local separator_start, separator_end = string.find(request, "\r\n\r\n", 1, true)
    if not separator_end then
        return nil
    end

    return string.sub(request, separator_end + 1)
end

local function handle_rpc(data)
    if type(data) ~= "table" then
        return {
            error = true,
            message = "Invalid JSON data",
        }
    end

    if data.func == "GetTimelineInfo" then
        return get_timeline_info()
    end

    if data.func == "AddSubtitles" then
        local payload = data.payload or data
        local ok, result = add_subtitles(payload)
        if ok then
            return result
        end

        return {
            error = true,
            message = result,
        }
    end

    if data.func == "Exit" then
        return {
            message = "Server shutting down",
            exit = true,
        }
    end

    return {
        error = true,
        message = "Unknown function name",
    }
end

local function start_server()
    local info = assert(socket.find_first_address(DEFAULT_SERVER_HOST, PORT))
    local server = assert(socket.create(info.family, info.socket_type, info.protocol))
    server:set_blocking(false)
    assert(server:set_option("nodelay", true, "tcp"))
    assert(server:set_option("reuseaddr", true))

    local bound = pcall(function()
        assert(server:bind(info))
    end)

    if not bound then
        send_exit_via_socket()
        os.execute("sleep 0.5")
        assert(server:bind(info))
    end

    assert(server:listen())
    log("Resolve bridge server is listening on port " .. PORT)

    if not DEV_MODE then
        launch_app()
    end

    local quit_server = false
    while not quit_server do
        local client, err = server:accept()
        if client then
            local peername = client:get_peer_name()
            if peername then
                assert(client:set_blocking(false))
                local request = read_request(client)
                local body = extract_request_body(request)
                local response_body = encode_json({
                    error = true,
                    message = "Invalid JSON data",
                })

                if body and #body > 0 then
                    local ok, data = pcall(parse_json, body)
                    if ok and data then
                        local result = handle_rpc(data)
                        if result.exit then
                            quit_server = true
                        end
                        response_body = encode_json(result)
                    else
                        response_body = encode_json({
                            error = true,
                            message = "Invalid JSON data",
                        })
                    end
                end

                local response = create_response(response_body)
                client:send(response)
                client:close()
            else
                client:close()
            end
        elseif err ~= "timeout" then
            log("Accept error: " .. tostring(err))
        end
    end

    log("Shutting down Resolve bridge server")
    server:close()
end

local AutoSubs = {}

function AutoSubs:Init(executable_path, resources_folder, dev_mode)
    DEV_MODE = dev_mode == true
    main_app = executable_path or DEFAULT_APP_PATH
    resources_path = resources_folder
    assets_path = join_path(resources_path, "AutoSubs")
    user_assets_path = os.getenv("HOME")
        and join_path(join_path(join_path(join_path(os.getenv("HOME"), "Library"), "Application Support"), "SubtitleStudioPlus"), "ResolveBridgeResources/AutoSubs")
        or nil
    current_session_id = new_session_id()

    local modules_path = join_path(resources_path, "modules")
    package.path = package.path .. ";" .. join_path(modules_path, "?.lua")

    socket = require("ljsocket")
    json = require("dkjson")

    refresh_project_state()
    start_server()
end

return AutoSubs
