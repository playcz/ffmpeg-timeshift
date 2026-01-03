set("log.stdout", true)
set("log.level", 3)
set("init.allow_root", true)

# ICECAST_URL comes from env
s = input.http(getenv("ICECAST_URL"))

# If source fails, produce silence instead of stopping
r = fallback(track_sensitive=false, [s, blank()])

# Output continuous WAV to FIFOs that ffmpeg reads
output.file(
  %wav(samplerate=int_of_string(getenv("AUDIO_SR")), channels=int_of_string(getenv("AUDIO_CH"))),
  "/tmp/hls.wav",
  r
)

output.file(
  %wav(samplerate=int_of_string(getenv("AUDIO_SR")), channels=int_of_string(getenv("AUDIO_CH"))),
  "/tmp/dash.wav",
  r
)