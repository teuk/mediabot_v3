#!/usr/bin/liquidsoap
#
# Mediabot v3 / Liquidsoap sample
#
# Source priority:
#   live input > request queue > global playlist
#
# Copy this file to /etc/liquidsoap/radio-8000.liq and replace placeholders.
# Do not commit real passwords.

set("log.file", true)
set("log.file.path", "/var/log/liquidsoap/radio-8000.log")
set("log.level", 3)

# Liquidsoap telnet control interface.
# Keep this local. Mediabot can use it to push queued requests.
set("server.telnet", true)
set("server.telnet.bind_addr", "127.0.0.1")
set("server.telnet.port", 1235)

# Live input.
# Use a non-conflicting port. Avoid ports already used by other radio stacks.
set("harbor.bind_addr", "0.0.0.0")
set("harbor.reverse_dns", true)

# Paths.
global_playlist_path = "/var/lib/mediabot-radio/playlists/global.m3u"
jingles_playlist_path = "/var/lib/mediabot-radio/playlists/jingles.m3u"

# Main playlist.
global_playlist = playlist(global_playlist_path, reload=7200, reload_mode="seconds")
global_playlist = audio_to_stereo(global_playlist)

# Optional jingles.
jingles = playlist(jingles_playlist_path, reload=7200, reload_mode="seconds")
jingles = audio_to_stereo(jingles)

# Live source.
# Replace LIVE_SOURCE_PASSWORD locally.
live = input.harbor("/", port=18005, password="LIVE_SOURCE_PASSWORD", icy=true)

# Mediabot request queue.
# Give it a stable id so it can be targeted from Liquidsoap telnet.
queue = request.queue(id="mediabot_queue")
queue = audio_to_stereo(queue)

# Playlist with occasional jingles.
radio = random(weights=[1, 20], [jingles, global_playlist])

# Priority:
#   1. live stream
#   2. Mediabot queue
#   3. playlist/jingles
full = fallback(track_sensitive=false, [live, queue, radio])

# Icecast output.
# Replace ICECAST_SOURCE_PASSWORD and public metadata locally.
output.icecast(
  %mp3(stereo=true, samplerate=44100, bitrate=192),
  host="127.0.0.1",
  port=8000,
  password="ICECAST_SOURCE_PASSWORD",
  mount="/radio.mp3",
  name="Mediabot Radio",
  description="Mediabot v3 sample radio stream",
  url="https://example.com/radio",
  public=false,
  fallible=true,
  full
)
