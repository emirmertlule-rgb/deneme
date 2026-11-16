local dfpwm = require("cc.audio.dfpwm")
local speaker = peripheral.wrap("left")

if not speaker then
    error("Hata: Sol tarafta hoparlör bulunamadı!")
end

print("Duman - Cambaz internetten akıtılıyor, lütfen bekleyin...")

-- Şarkı dosyasını diske indirmeden doğrudan internetten parça parça çekiyoruz
local response = http.get("https://raw.githubusercontent.com/emirmertlule-rgb/deneme/main/cambaz.dfpwm", nil, true)

if not response then
    error("Hata: Ses dosyasına internet üzerinden ulaşılamadı!")
end

local decoder = dfpwm.make_decoder()

while true do
    local chunk = response.read(16 * 1024)
    if not chunk then break end
    
    local buffer = decoder(chunk)
    while not speaker.playAudio(buffer) do
        os.pullEvent("speaker_audio_empty")
    end
end

response.close()
print("Şarkı bitti!")
