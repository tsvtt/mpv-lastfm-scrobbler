mp = require('mp')

local SCR_FORMATS = {
    mp3 = true,
    flac = true,
    m4a = true,
}
PLUGIN_NAME = 'lastfm_scr'
SCR_URL = 'http://ws.audioscrobbler.com/2.0/?format=json'
S = '1c62855d245db87aa72d97e04628dfa2'
K = '7c58d2ae379ba37916c438c88455ec03'
URL_K = SCR_URL .. '&api_key=' .. K
SCRIPTS_DIR = mp.find_config_file('scripts')
CONF_FILENAME = '.' .. PLUGIN_NAME .. '.conf'
TMP_FILEPATH = '/tmp/' .. PLUGIN_NAME .. '.temp'
CONF_FILEPATH = SCRIPTS_DIR .. '/'  .. CONF_FILENAME
local SCR_SEC = 90
local JSON_VALUE_RE = '":%s?"([^"]+)'
local uname, sk, timer
local is_paused = false

API_METHODS = {
    getSession = 'auth.getSession',
    getToken = 'auth.gettoken',
    scrobble = 'track.scrobble',
}

subpr_cmd_table = {
    name = "subprocess",
    args = nil,
    playback_only = false,
    capture_stdout = true,
    capture_stderr = true,
}

logger = {
    _log = function(lvl, ...) mp.msg[lvl:lower()](os.date("%H:%M:%S") .. ' ' .. lvl .. ':', ...) end,
    error = function(...) logger._log('ERROR', ...) end,
    info = function(...) logger._log('INFO', ...) end,
    debug = function(...) logger._log('DEBUG', ...) end,
}

function trim(s)
    return s and s:match "^%s*(.*)":match "(.-)%s*$"
end

function empty(v)
    return not v or v == ''
end

function subpr_reporter(res)
    if not res then return end
    -- if not res or not res.status then return end  -- ??

    if res.status == 0 then
        logger.debug('Subpr stdout:', res.stdout)
    elseif res.status then
        logger.error('Subpr stdout:', res.stdout)
        logger.error('Subpr stderr:', res.stderr)
    else
        logger.debug('Subpr ret code:', res.status)
    end
    return res
end

---@param args table
---@return table
function run_subpr_sync(args)
    subpr_cmd_table.args = args
    local res = mp.command_native(subpr_cmd_table)
    return subpr_reporter(res)
end

---@param args table
---@param cb function?
---@return table
function run_subpr_async(args, cb)
    subpr_cmd_table.args = args
    local res = mp.command_native_async(subpr_cmd_table, cb)
    return subpr_reporter(res)
end

---@return string
function curl_get(url)
    return run_subpr_sync({ 'curl', url }).stdout
end

---@param url string
---@param kv_pairs string
---@return string
function curl_post(url, kv_pairs)
    return run_subpr_sync({ 'curl', '-d', kv_pairs, url }).stdout
end

function api_fetch_token()
    local resp_text = curl_get(URL_K .. '&method=' .. API_METHODS.getToken)
    local token = resp_text and resp_text:match('token' .. JSON_VALUE_RE)
    logger.debug('Fetched token:', token)
    return token
end

function str_to_md5(str)
    local tmpfile = assert(io.open(TMP_FILEPATH, 'w'))
    tmpfile:write(str)
    tmpfile:close()
    return (run_subpr_sync(
        {
            'md5sum',
            TMP_FILEPATH,
        }
    ).stdout):match('^%S+')
end

function gen_sig(method, token, _sk, md)
    local sig = 'api_key' .. K

    if method == API_METHODS.getSession then
        sig = sig .. 'method' .. method .. 'token' .. token
    elseif method == API_METHODS.scrobble then
        sig =
            'album[0]' .. md.album ..
            sig ..
            'artist[0]' .. md.artist ..
            'method' .. method ..
            'sk' .. _sk ..
            'timestamp[0]' .. os.time() - SCR_SEC ..
            'track[0]' .. md.title
    else
        logger.error('Incorrect method:', method)
        return
    end
    sig = sig .. S
    logger.debug('Generated sig: ', sig)
    sig = trim(str_to_md5(sig))
    logger.debug('Hashed sig:', sig)
    return sig
end

function new_session_notify_user(token)
    local url = 'http://www.last.fm/api/auth/?api_key=' .. K .. '&token=' .. token
    print('\n*************************************************************\n')
    print('last.fm requires manual session confirmation. Open the link in a browser and confirm the session:')
    print(url)
    print('\n**************************************************************\n')
    run_subpr_async({ 'xdg-open', url })
end

function api_fetch_session(token, sig)
    local url = URL_K .. '&method=' .. API_METHODS.getSession .. '&token=' .. token .. '&api_sig=' .. sig
    logger.debug('Requesting URL:', url)
    local resp_text = curl_get(url)
    return resp_text
end

function table_to_urlencoded(table)
    local s = ''
    for k, v in pairs(table) do
        s = s .. k .. '=' .. v .. '&'
    end
    return s:sub(0, s:len() - 1)
end

function extract_playmetadata()
    return {
        artist = mp.get_property("metadata/by-key/artist") or '',
        title = mp.get_property("metadata/by-key/title") or '',
        album = mp.get_property("metadata/by-key/album") or '',
    }
end

function filename() return mp.get_property('filename') end
function file_ext() return filename():match('%.(%w+)$') end

function scrobble()
    local md = extract_playmetadata()
    local sig = gen_sig(API_METHODS.scrobble, nil, sk, md)
    if empty(sig) or empty(md.artist) or empty(md.title) then
        logger.error("Can't scrobble: empty value among required values:",
            'sig=', sig, ',artist=', md.artist, ',title=', md.title)
        return
    end
    curl_post(
        SCR_URL,
        table_to_urlencoded(
            {
                ['album[0]'] = md.album,
                api_key = K,
                api_sig = sig,
                method = API_METHODS.scrobble,
                sk = sk,
                ['artist[0]'] = md.artist,
                ['timestamp[0]'] = os.time() - SCR_SEC,
                ['track[0]'] = md.title,
            }
        )
    )
end

function set_scrobble_timer()
    if SCR_FORMATS[file_ext()] then
        timer = mp.add_timeout(SCR_SEC, scrobble)
        if is_paused then
            timer:stop()
        end
    else
        logger.debug('Extension "' .. file_ext() .. '" is not set for scrobbling')
    end
end

function clear_timer()
    if timer then
        logger.debug('clearing the timer')
        timer:kill()
    end
end

function on_file_loaded(_ev)
    logger.debug('file loaded event')
    set_scrobble_timer()
end

function on_file_ended(ev)
    logger.debug('file ended event')
    if ev.reason ~= 'redirect' then
        -- todo: why redirect is sent when playing a file?
        clear_timer()
    end
end

function on_pause(_name, is_paused_ev)
	if is_paused_ev == true then
	    is_paused = true
	    if timer then timer:stop() end
    else
	    is_paused = false
        if timer then timer:resume() end
    end
end

function init_mpv_handlers()
    logger.debug('init mpv handlers')
    mp.register_event("file-loaded", on_file_loaded)
    mp.register_event("end-file", on_file_ended)
    mp.observe_property("pause", "bool", on_pause)
end

function wait_session_approve(token, sig)
    local times = 15

    function fetch_creds()
        local session_resp = api_fetch_session(token, sig)
        if session_resp then
            uname = session_resp:match('name' .. JSON_VALUE_RE)
            sk = session_resp:match('key' .. JSON_VALUE_RE)
        end
    end

    function fetch_creds_loop(...)
        fetch_creds()
        if sk then
            logger.info('Session confirmed with uname=', uname, ' sk=', sk)
            complete_userdata()
        elseif times > 0 then
            logger.debug('Waiting for the user to confirm the session...')
            times = times - 1
            run_subpr_async({ 'sleep', '10' }, fetch_creds_loop)
        else
            logger.error("Can't proceed: API-session wasn't approved by the user")
        end
    end

    fetch_creds_loop()
end

function read_conffile()
    local f = io.open(CONF_FILEPATH, 'r')
    if not f then return; end
    local line = f:read()
    while line do
        uname = uname or line:match('^uname=(.+)')
        sk = sk or line:match('^sk=(.+)')
        line = f:read()
    end
    f:close()
    logger.debug('uname=', uname, ', sk=', sk)
end

function write_conffile()
    logger.debug('Writing conffile')
    local f = io.open(CONF_FILEPATH, 'w')
    if not f then
        logger.error("Can't open", CONF_FILEPATH, 'for_ writing')
        return
    end
    f:write('uname=' .. uname .. '\n')
    f:write('sk=' .. sk .. '\n')
    f:close()
    return true
end

function setup_userdata()
    logger.debug('init userdata')
    local token = api_fetch_token()
    if not token then
        logger.error('token is nil')
        return
    end

    local sig = gen_sig(API_METHODS.getSession, token)
    if not sig then
        logger.error('sig is nil')
        return
    end

    new_session_notify_user(token)
    wait_session_approve(token, sig)
    if not sk then
        logger.error('sk is nil')
        return
    end
    return true
end

function complete_userdata()
    _ = write_conffile() and init_mpv_handlers()
end

function find_curl()
    if run_subpr_sync({ 'which', 'curl' }).status == 0 then
        return true
    else
        logger.error('curl is not found. This plugin requires curl for network requests to last.fm.')
    end
end

function main()
    read_conffile()
    if not sk then
        setup_userdata()
    else
        init_mpv_handlers()
    end
end

_ = find_curl() and main()
