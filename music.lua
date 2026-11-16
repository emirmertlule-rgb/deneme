-- music.lua : CC:Tweaked YouTube streaming oynatici
local dfpwm = require("cc.audio.dfpwm")

local SERVER = (settings.get("music.server", "http://127.0.0.1:8080"):gsub("/+$", ""))
local CHUNK, BYTES_PER_SEC, PREFETCH = 16 * 1024, 6000, 3   -- 48 kHz / 8 bit = 6000 byte/sn
local volume = tonumber(settings.get("music.volume", 1.0)) or 1.0
local paused, skip = false, false

local speakers = { peripheral.find("speaker") }
if #speakers == 0 then error("Hoparlor bulunamadi! Bilgisayarin yanina hoparlor koy.", 0) end

local okUrl, urlErr = http.checkURL(SERVER)
if not okUrl then
  error("Sunucuya erisilemiyor: " .. tostring(urlErr) ..
        "\ncomputercraft-server.toml'da http kurallarini kontrol et.", 0)
end

local function ascii(s) return (tostring(s):gsub("[\128-\255]+", "?")) end
local function stopAll() for _, sp in ipairs(speakers) do sp.stop() end end

local function fmt(sec)
  sec = math.floor(sec)
  return ("%d:%02d"):format(math.floor(sec / 60), sec % 60)
end

local function prepare(q)
  local h, err, eh = http.get(SERVER .. "/prepare?q=" .. textutils.urlEncode(q), nil, true)
  if not h then
    local msg = tostring(err)
    if eh then msg = eh.readAll() or msg; eh.close() end
    return nil, msg
  end
  local body = h.readAll(); h.close()
  local id, title = body:match("^([^\n]+)\n(.*)$")
  if not id then return nil, "Sunucudan gecersiz cevap" end
  return id, ascii(title)
end

local function playSong(id, title)
  local decoder = dfpwm.make_decoder()
  local store, inflight, fails = {}, {}, {}
  local n, status, lastErr = 0, "Tamponlaniyor...", nil
  skip, paused = false, false

  local function draw()
    local w = term.getSize()
    term.setCursorPos(1, 1); term.clearLine()
    term.write(("Calan: " .. title):sub(1, w))
    term.setCursorPos(1, 2); term.clearLine()
    term.write(("Sure: %s   Ses: %d%%   %s"):format(
      fmt(n * CHUNK / BYTES_PER_SEC), math.floor(volume * 100 + 0.5), paused and "[DURAKLATILDI]" or status))
    term.setCursorPos(1, 3); term.clearLine()
    term.write("[SPACE] duraklat  [S] atla  [UP/DOWN] ses")
    term.setCursorPos(1, 5); term.clearLine()
    if lastErr then term.write(("Hata: " .. lastErr):sub(1, w)) end
  end

  local function request(i)
    if store[i] ~= nil then return end
    for _, v in pairs(inflight) do if v == i then return end end
    local url = ("%s/chunk?id=%s&n=%d"):format(SERVER, id, i)
    inflight[url] = i
    http.request({ url = url, binary = true })
  end

  local function handle(ev)
    local e, a, b, c = ev[1], ev[2], ev[3], ev[4]
    if e == "http_success" and inflight[a] then
      local i = inflight[a]; inflight[a] = nil
      local code = b.getResponseCode()
      local data = b.readAll(); b.close()
      if code == 204 or not data or #data == 0 then store[i] = false else store[i] = data end
    elseif e == "http_failure" and inflight[a] then
      local i = inflight[a]; inflight[a] = nil
      if c then lastErr = ascii(c.readAll() or b); c.close() else lastErr = ascii(b) end
      fails[i] = (fails[i] or 0) + 1
      if fails[i] >= 3 then store[i] = false else request(i) end
    elseif e == "key" then
      if a == keys.space then
        paused = not paused
        if paused then stopAll() end
      elseif a == keys.s or a == keys.n then
        skip = true
      elseif a == keys.up then
        volume = math.min(3, math.floor((volume + 0.1) * 10 + 0.5) / 10)
      elseif a == keys.down then
        volume = math.max(0, math.floor((volume - 0.1) * 10 + 0.5) / 10)
      end
    end
  end

  local function pump()
    draw()
    handle({ os.pullEvent() })
  end

  local function feed(buf)
    local fed = {}
    while not skip do
      if paused then
        while paused and not skip do pump() end
        fed = {}                       -- duraklatma sonrasi parcayi bastan cal
      end
      local all = true
      for i, sp in ipairs(speakers) do
        if not fed[i] then
          if sp.playAudio(buf, volume) then fed[i] = true else all = false end
        end
      end
      if all then return end
      pump()
    end
  end

  for i = 0, PREFETCH do request(i) end

  while not skip do
    status = "Tamponlaniyor..."
    while store[n] == nil and not skip do pump() end
    if skip then break end
    local data = store[n]
    store[n] = nil
    if data == false then break end    -- sarki bitti (veya 3 kez hata)
    status = "Caliyor"
    feed(decoder(data))
    n = n + 1
    request(n + PREFETCH)
    draw()
  end

  stopAll()
  settings.set("music.volume", volume); settings.save()
end

local function run(q)
  term.clear(); term.setCursorPos(1, 1)
  print("Araniyor: " .. q)
  local id, title = prepare(q)
  if not id then printError(title); sleep(3); return end
  term.clear()
  local ok, err = pcall(playSong, id, title)
  stopAll()
  if not ok then
    if tostring(err):find("Terminated") then error(err, 0) end
    printError(err); sleep(3)
  end
end

local args = { ... }
if #args > 0 then run(table.concat(args, " ")) end

while true do
  term.clear(); term.setCursorPos(1, 1)
  print("YouTube Muzik Calar   (cikis: exit)")
  write("Sarki adi / link > ")
  local q = read()
  if not q or q == "exit" then break end
  if q ~= "" then run(q) end
end
term.clear(); term.setCursorPos(1, 1)
