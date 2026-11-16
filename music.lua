-- music.lua : CC:Tweaked YouTube streaming oynatici (sira + dongu)
local dfpwm = require("cc.audio.dfpwm")

local SERVER = (settings.get("music.server", "http://127.0.0.1:8080"):gsub("/+$", ""))
local CHUNK, BYTES_PER_SEC, PREFETCH = 16 * 1024, 6000, 3   -- 48 kHz / 8 bit = 6000 byte/sn
local volume = tonumber(settings.get("music.volume", 1.0)) or 1.0

local speakers = { peripheral.find("speaker") }
if #speakers == 0 then error("Hoparlor bulunamadi! Bilgisayarin yanina hoparlor koy.", 0) end

local okUrl, urlErr = http.checkURL(SERVER)
if not okUrl then
  error("Sunucuya erisilemiyor: " .. tostring(urlErr) ..
        "\ncomputercraft-server.toml'da http kurallarini kontrol et.", 0)
end

-- ---------------------------------------------------------------- durum
local queue, current, S = {}, nil, nil     -- sira, calan sarki, calan sarkinin parca durumu
local loopMode = 0                          -- 0 kapali, 1 sarki, 2 liste
local LOOP_NAMES = { [0] = "kapali", [1] = "SARKI", [2] = "LISTE" }
local paused, skip, stop = false, false, false
local inputMode, inputBuf, eatChar = false, "", nil
local prepReq, prepCount = {}, 0
local message, lastBufLen = nil, 0

local function ascii(s) return (tostring(s):gsub("[\128-\255]+", "?")) end
local function stopAll() for _, sp in ipairs(speakers) do sp.stop() end end
local function fmt(sec)
  sec = math.floor(sec)
  return ("%d:%02d"):format(math.floor(sec / 60), sec % 60)
end
local function halted() return skip or stop or (S ~= nil and S.expired) end

-- ---------------------------------------------------------------- hazirlama (sunucuya "bu sarkiyi hazirla" der)
local function prepareAsync(ent)
  prepCount = prepCount + 1
  local url = ("%s/prepare?q=%s&r=%d"):format(SERVER, textutils.urlEncode(ent.query), prepCount)
  ent.state = "preparing"
  prepReq[url] = ent
  http.request({ url = url, binary = true })
end

local function addToQueue(q)
  q = q:match("^%s*(.-)%s*$")
  if q == "" then return end
  queue[#queue + 1] = { query = q, state = "new" }
  message = "Siraya eklendi: " .. ascii(q)
end

-- siradaki sarkiyi, calan sarki calarken onceden hazirlat
local function ensureNextPrepared()
  local nxt = queue[1]
  if nxt and nxt.state == "new" and loopMode ~= 1 and current and current.state == "ready" then
    prepareAsync(nxt)
  end
end

-- ---------------------------------------------------------------- ekran
local function draw()
  local w, h = term.getSize()
  local function line(y, text)
    term.setCursorPos(1, y); term.clearLine(); term.write(tostring(text):sub(1, w))
  end
  local title = current and ascii(current.title or current.query) or ""
  if current and current.state ~= "ready" then line(1, "Hazirlaniyor: " .. title)
  else line(1, "Calan: " .. title) end
  local el = S and (S.n * CHUNK / BYTES_PER_SEC) or 0
  line(2, ("Sure: %s  Ses: %d%%  Dongu: %s"):format(fmt(el), math.floor(volume * 100 + 0.5), LOOP_NAMES[loopMode]))
  line(3, paused and "[DURAKLATILDI]" or (S and S.status or ""))
  line(4, "SPACE dur  S atla  X durdur  L dongu")
  line(5, "A sira ekle  C sirayi temizle  UP/DN ses")
  line(6, message or (S and S.lastErr and ("Hata: " .. S.lastErr)) or "")
  line(7, ("Sirada (%d):"):format(#queue))
  for y = 8, h do line(y, "") end
  local rows = h - 8
  for i = 1, math.min(#queue, rows) do
    local e = queue[i]
    local t = ascii(e.title or e.query)
    if e.state == "error" then t = t .. " (hata)" end
    line(7 + i, ("%d. %s"):format(i, t))
  end
  if #queue > rows then line(h - 1, ("... +%d daha"):format(#queue - rows)) end
  if inputMode then line(h, "Ekle> " .. inputBuf .. "_") end
end

-- ---------------------------------------------------------------- olaylar
local function request(i)
  local s = S
  if s.store[i] ~= nil then return end
  for _, v in pairs(s.inflight) do if v == i then return end end
  local url = ("%s/chunk?id=%s&n=%d"):format(SERVER, s.id, i)
  s.inflight[url] = i
  http.request({ url = url, binary = true })
end

local function handle(ev)
  local e, a, b, c = ev[1], ev[2], ev[3], ev[4]

  if e == "http_success" or e == "http_failure" then
    local ent = prepReq[a]
    if ent then                                   -- /prepare cevabi
      prepReq[a] = nil
      if e == "http_success" then
        local body = b.readAll() or ""; b.close()
        local id, title = body:match("^([^\n]+)\n(.*)$")
        if id then ent.id, ent.title, ent.state = id, ascii(title), "ready"
        else ent.state, ent.err = "error", "Sunucudan gecersiz cevap" end
      else
        local msg = tostring(b)
        if c then msg = c.readAll() or msg; c.close() end
        ent.state, ent.err = "error", ascii(msg)
      end
    elseif S and S.inflight[a] then               -- /chunk cevabi
      local i = S.inflight[a]; S.inflight[a] = nil
      if e == "http_success" then
        local code = b.getResponseCode()
        local data = b.readAll(); b.close()
        if code == 204 or not data or #data == 0 then S.store[i] = false else S.store[i] = data end
      else
        local code = c and c.getResponseCode() or nil
        local msg = tostring(b)
        if c then msg = c.readAll() or msg; c.close() end
        S.lastErr = ascii(msg)
        if code == 404 then
          S.expired = true                        -- sunucu bu sarkiyi unutmus: yeniden hazirlanacak
        else
          S.fails[i] = (S.fails[i] or 0) + 1
          if S.fails[i] >= 3 then S.store[i] = false else request(i) end
        end
      end
    end

  elseif e == "char" or e == "paste" then
    if inputMode then
      if e == "char" and eatChar and a:lower() == eatChar then eatChar = nil   -- "A" tusunun harfini yut
      else eatChar = nil; inputBuf = inputBuf .. a end
    end

  elseif e == "key" then
    if inputMode then
      if a == keys.enter then
        inputMode = false; addToQueue(inputBuf); inputBuf = ""      -- bos Enter = iptal
      elseif a == keys.backspace then
        inputBuf = inputBuf:sub(1, -2)
      end
    elseif a == keys.space then
      paused = not paused
      if paused then stopAll() end
    elseif a == keys.s or a == keys.n then
      skip = true
    elseif a == keys.x then
      stop = true; queue = {}
    elseif a == keys.l then
      loopMode = (loopMode + 1) % 3
      message = "Dongu: " .. LOOP_NAMES[loopMode]
    elseif a == keys.a then
      inputMode, inputBuf, eatChar = true, "", "a"
    elseif a == keys.c then
      queue = {}; message = "Sira temizlendi"
    elseif a == keys.up then
      volume = math.min(3, math.floor((volume + 0.1) * 10 + 0.5) / 10)
    elseif a == keys.down then
      volume = math.max(0, math.floor((volume - 0.1) * 10 + 0.5) / 10)
    end
  end
end

local function pump()
  ensureNextPrepared()
  draw()
  handle({ os.pullEvent() })
end

-- ---------------------------------------------------------------- calma
local function feed(buf)
  local fed = {}
  while not halted() do
    if paused then
      while paused and not halted() do pump() end
      fed = {}                          -- duraklatma sonrasi parcayi bastan cal
    end
    local all = true
    for i, sp in ipairs(speakers) do
      if not fed[i] then
        if sp.playAudio(buf, volume) then fed[i] = true else all = false end
      end
    end
    if all then lastBufLen = #buf; return end
    pump()
  end
end

-- sarki dogal olarak bitti ve sirada baska sey yok: hoparlordeki son parcanin bitmesini bekle
local function drain(len)
  S = nil
  local sec = len / 48000
  local t1 = os.startTimer(sec / 2)       -- bundan onceki "bos" olaylari eski sayilir
  local t2 = os.startTimer(sec * 2 + 4)   -- en fazla bekleme
  local t1done, empty, count = false, {}, 0
  while not (stop or skip) and #queue == 0 and loopMode == 0 do
    draw()
    local ev = { os.pullEvent() }
    if ev[1] == "timer" and ev[2] == t1 then t1done = true
    elseif ev[1] == "timer" and ev[2] == t2 then break
    elseif ev[1] == "speaker_audio_empty" and t1done then
      if not empty[ev[2]] then empty[ev[2]] = true; count = count + 1 end
      if count >= #speakers then break end
    else handle(ev) end
  end
end

local function playSong(ent)
  local decoder = dfpwm.make_decoder()
  S = { id = ent.id, store = {}, inflight = {}, fails = {}, n = 0, status = "Tamponlaniyor...", expired = false }
  local s = S
  skip, paused = false, false
  for i = 0, PREFETCH do request(i) end

  local result = "ended"
  while true do
    s.status = "Tamponlaniyor..."
    while s.store[s.n] == nil and not halted() do pump() end
    if stop then result = "stop"; break end
    if skip then result = "skip"; break end
    if s.expired then result = "expired"; break end
    local data = s.store[s.n]
    s.store[s.n] = nil
    if data == false then
      if s.n == 0 then result = "error" end      -- hic parca gelmediyse hata say (donguye sokma)
      break
    end
    s.status = "Caliyor"
    ent.retried = false
    feed(decoder(data))
    s.n = s.n + 1
    request(s.n + PREFETCH)
  end
  if result == "error" then message = "Hata: " .. (s.lastErr or "parca alinamadi") end
  return result
end

-- calan sarki bitince/atlaninca siradaki sarkiyi sec
local function pickNext(ent, reason)
  if reason == "ended" and loopMode == 1 then return ent end        -- sarki dongusu
  if loopMode == 2 then queue[#queue + 1] = ent end                 -- liste dongusu: sona ekle
  local nxt = table.remove(queue, 1)
  if loopMode == 1 and not nxt then nxt = ent end                   -- dongude atla = bastan
  return nxt
end

local function player(first)
  current, queue, stop, message = first, {}, false, nil
  local errmsg
  while current and not stop do
    local ent = current
    skip = false
    if ent.state == "new" then prepareAsync(ent) end
    while ent.state == "preparing" and not (skip or stop) do pump() end

    local result
    if stop then break end
    if skip then result = "skip"
    elseif ent.state ~= "ready" then
      message = "Hata: " .. ascii(ent.err or "?"); result = "error"
    else result = playSong(ent) end

    local nxt
    if result == "stop" then break
    elseif result == "expired" then
      if ent.retried then
        message = "Hata: sarki sunucudan silinmis"; errmsg = message
        nxt = table.remove(queue, 1)
      else
        ent.retried, ent.state, ent.id = true, "new", nil           -- yeniden hazirlatip tekrar dene
        nxt = ent
      end
    elseif result == "error" then
      errmsg = message
      nxt = table.remove(queue, 1)                                  -- hatali sarkiyi atla, donguye sokma
    else
      if result == "skip" then stopAll() end
      nxt = pickNext(ent, result)
      if nxt == nil and result == "ended" then
        drain(lastBufLen)
        if stop then break end
        if skip then stopAll() end
        nxt = pickNext(ent, "ended")
      end
    end
    S = nil
    current = nxt
  end
  stopAll()
  S, current, inputMode = nil, nil, false
  settings.set("music.volume", volume); settings.save()
  return errmsg
end

local function run(q)
  term.clear(); term.setCursorPos(1, 1)
  local ok, res = pcall(player, { query = q, state = "new" })
  stopAll()
  S, current, inputMode = nil, nil, false
  if not ok then
    if tostring(res):find("Terminated") then error(res, 0) end
    printError(res); sleep(3)
  elseif res then
    printError(res); sleep(3)
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
