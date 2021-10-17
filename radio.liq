#!/usr/bin/liquidsoap --debug -U

# Log dir
set("log.file.path","/var/log/liquidsoap/liquidsoap.log")

# General log level
set("log.level",3)

# Log scheduler messages
set("scheduler.log",true)

#Set debugging mode
set("decoder.debug",false)


# Run in daemon mode
set("init.daemon",true)

# Support for pidfile generation
set("init.daemon.pidfile",true)

# Path to pidfile
set("init.daemon.pidfile.path","/var/run/liquidsoap/liquidsoap.pid")

# Support for communication via a telnet interface
set("server.telnet",true)

# Network mask from which the telnet server should accept connections
set("server.telnet.bind_addr","127.0.0.1")

# Port on which the telnet server should listen
set("server.telnet.port",1234)

# IP address on which the HTTP stream receiver should listen.
set("harbor.bind_addr","0.0.0.0")

# Perform reverse DNS lookup to get the client's hostname from its IP.
set("harbor.reverse_dns",true)

# Resampling quality (one of: best,medium,fast,zero_order,linear. Refer to ocaml-samplerate for details.)
#set("audio.converter.samplerate.libsamplerate.quality","best")
set("audio.converter.samplerate.libsamplerate.quality","fast")

# Music
global_playlist = playlist("/home/mp3/plglob.m3u",reload=7200,reload_mode="seconds")
global_playlist = audio_to_stereo(global_playlist)

jingles = playlist("/home/mp3/jingles.m3u")

live = input.harbor("/",port=8005,password="mysourcepassword",icy=true)

# Start building the feed with music
radio = global_playlist

radio = random(weights = [1, 20],[jingles, radio])

# Add a request queue
queue = request.queue()
queue = audio_to_stereo(queue)

full = fallback(track_sensitive=false,[live,queue,radio])

output.icecast(%mp3(stereo=true, samplerate=48000, bitrate=320),
  host="localhost",
  port=8000,
  password="myicecastsourcepassword",
  mount="radio.mp3",
  description="My Fancy Radio",
  url="https://mysuperfancyurl123.com",
  public=false,
  fallible=true,
  full)
  
