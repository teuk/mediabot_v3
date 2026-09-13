# MB734: control only the final radio selector, never two independent skips.
# Load before output.icecast, then wrap its fallback source with this function.
# Requires Liquidsoap 2.3.x. The telnet server must remain on loopback.
def mediabot_next_control(program, live, queue)
  epoch = "#{time()}-#{random.int(min=0, max=1000000000)}"
  serial = ref(0)
  pending = ref("")
  outcome = ref("idle")
  metadata = ref([])
  observed_origin = ref("none")
  def origin()
    selected = program.selected()
    if null.defined(selected) then
      id = source.id(null.get(selected))
      if id == live.id() then "live"
      elsif id == queue.id() then "queue"
      else "playlist" end
    else "none" end
  end
  def token() = "#{epoch}:#{serial()}" end
  def state(_)
    json.stringify(compact=true, {protocol=1, epoch=epoch, serial=serial(),
      origin=if origin() == observed_origin() then observed_origin() else "none" end, pending=pending() != "", outcome=outcome(),
      artist=list.assoc(default="", "artist", metadata()),
      title=list.assoc(default="", "title", metadata())})
  end
  def advance(expected)
    if expected != token() then "stale"
    elsif pending() != "" then "busy"
    elsif origin() == "live" then "live"
    elsif origin() == "none" then "unavailable"
    else
      pending := expected
      outcome := "pending"
      "accepted"
    end
  end
  # Execute in the same streaming clock as selection and track boundaries.
  # A natural transition between HTTP inspection and this frame invalidates it.
  def frame()
    if pending() != "" and outcome() == "pending" then
      if pending() != token() then
        outcome := "stale"
        pending := ""
      elsif origin() == "live" or origin() == "none" then
        outcome := "unavailable"
        pending := ""
      else
        outcome := "sent"
        program.skip()
      end
    end
  end
  controlled = source.on_frame(program, frame)
  def started(m)
    metadata := m
    observed_origin := origin()
    serial := serial() + 1
    if outcome() == "sent" then
      outcome := "completed"
      pending := ""
    end
  end
  controlled.on_track(started)
  # Returning to an interrupted playlist replays metadata without a new track
  # marker. Record that real source change as well as ordinary new tracks.
  def updated(m)
    if origin() != observed_origin() then started(m)
    else metadata := m end
  end
  controlled.on_metadata(updated)
  server.register("mediabot.control_state", state)
  server.register("mediabot.control_next", advance)
  controlled
end
