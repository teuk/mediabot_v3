# =============================================================================
# partwatch.tcl — Mediabot v3 reference plugin script (mediabot-script-v1), Tcl.
#
# The TCL reference for CHANNEL EVENT routes (mb529/mb533), wired to the
# `part` event in the sample configuration:
#
#   EVENTS=part=examples/partwatch.tcl
#
# When someone leaves a routed channel, the bridge re-runs this script with
# event "part"; the envelope carries channel/nick and the part reason in the
# dedicated "message" field (compare: `join` routes receive ident/host,
# `topic` routes receive the new topic). The script says goodbye in the SAME
# channel, quoting the reason when one was given.
#
# Field extraction uses the same dependency-free regexp style as
# hello_tcl.tcl/eightball.tcl (the class [^"\\]* stops at a quote/backslash);
# for exotic input a real JSON parser (tcllib's json) is recommended.
#
# Event guardrails (enforced upstream): opt-in EVENTS route only, the bot's
# own part never triggers scripts, anti-burst cooldown per event/channel —
# during a netsplit most parts are counted and ignored, so never design a
# part script that assumes it sees every departure. When routed to an
# unexpected event this script logs a warning and stays silent on IRC.
# =============================================================================

set input [read stdin]

# --- minimal JSON string escaper --------------------------------------------
proc json_escape {value} {
    return [string map [list \\ \\\\ \" \\\" \n \\n \r \\r \t \\t] $value]
}

# --- minimal field extraction (no JSON parser) -------------------------------
set event "unknown"
if {[regexp {"event"[ \t\r\n]*:[ \t\r\n]*"([^"\\]*)"} $input -> extracted_event]} {
    if {$extracted_event ne ""} {
        set event $extracted_event
    }
}

set nick "someone"
if {[regexp {"nick"[ \t\r\n]*:[ \t\r\n]*"([^"\\]*)"} $input -> extracted_nick]} {
    if {$extracted_nick ne ""} {
        set nick $extracted_nick
    }
}

set reason ""
if {[regexp {"message"[ \t\r\n]*:[ \t\r\n]*"([^"\\]*)"} $input -> extracted_reason]} {
    set reason $extracted_reason
}

# --- build the actions --------------------------------------------------------
set actions {}

if {$event eq "part"} {
    if {$reason ne ""} {
        set text "goodbye $nick (\"$reason\")"
    } else {
        set text "goodbye $nick"
    }
    lappend actions "{\"type\": \"reply\", \"text\": \"[json_escape $text]\"}"
    lappend actions "{\"type\": \"log\", \"level\": \"info\", \"text\": \"[json_escape "partwatch: $nick left"]\"}"
} else {
    # Routed to something unexpected: log it, stay silent on IRC.
    lappend actions "{\"type\": \"log\", \"level\": \"warning\", \"text\": \"[json_escape "partwatch: unexpected event '$event' (route me to part only)"]\"}"
}

# --- emit the contract --------------------------------------------------------
puts -nonewline "{\"protocol\": \"mediabot-script-v1\", \"ok\": true, \"actions\": \[[join $actions ", "]\]}"
