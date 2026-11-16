local dfpwm = require("cc.audio.dfpwm")
local speaker = peripheral.wrap("left")

if not speaker then
    error("Hata: Sol tarafta hoparlör bulunamadı! Bitişik olduğundan emin ol.")
end

local decoder = dfpwm.make_decoder()
local file = io.open("cambaz.dfpwm", "rb")

if not file then
    error("Hata: 'cambaz.dfpwm' dosyası bulunamadı! Önce ses dosyasını indirdiğinden emin ol.")
end

print("Duman - Cambaz çalınıyor... Keyifli dinlemeler!")

for chunk in file:lines(16 * 1024) do
    local buffer = decoder(chunk)
    while not speaker.playAudio(buffer) do
        os.pullEvent("speaker_audio_empty")
    end
end

file:close()
print("Şarkı bitti!")
