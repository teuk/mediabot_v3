# =============================================================================
# greeter.tcl — Mediabot v3 plugin-v2 EVENT example (mediabot-script-v1), Tcl.
#
# The mb593 showcase: this script declares NO command at all. Its sidecar
# (greeter.tcl.manifest.json) declares an EVENT, and the PluginManager
# subscribes for you — every join on a watched channel runs this script:
#
#   .plugins loadscript examples-v2/greeter.tcl        (partyline, Owner)
#
#   * SlaY joins #quebec  ->  "Welcome aboard, SlaY! Pull up a chair."
#   * the bot itself joins -> silence (is_self guard, cookbook pattern 6)
#
# The envelope carries the observed scalar context under data.* — for a
# channel_join_observed event: event_type, channel, nick, is_self (plus
# ident/host when known). Same dependency-free technique as lart.tcl.
# Failures never notice anyone: an event has no caller (mb593 rule 6).
# =============================================================================

set input [read stdin]

proc json_escape {value} {
    return [string map [list \\ \\\\ \" \\\" \n \\n \r \\r \t \\t] $value]
}

# The bot's own join must stay silent: succeed with zero actions.
if {[regexp {"is_self"[ \t\r\n]*:[ \t\r\n]*"?(1|true)"?} $input]} {
    puts "{\"ok\": true, \"protocol\": \"mediabot-script-v1\", \"actions\": \[\]}"
    exit 0
}

set nick "friend"
if {[regexp {"nick"[ \t\r\n]*:[ \t\r\n]*"([^"\\]*)"} $input -> extracted_nick]} {
    if {$extracted_nick ne ""} {
        set nick [string range $extracted_nick 0 29]
    }
}

# mb600: a configured GREETING (sidecar defaults, overridable from the
# bot's conf as plugins.greeter.GREETING) replaces the pool — change the
# welcome line without editing this script. %s receives the nick.
set configured ""
if {[regexp {"GREETING"[ \t\r\n]*:[ \t\r\n]*"([^"\\]*)"} $input -> extracted_greeting]} {
    set configured $extracted_greeting
}
if {$configured ne ""} {
    # Treat %s as a literal placeholder, not as a Tcl format program:
    # operator text such as "100% welcome, %s" must never crash the script.
    set line [string map [list %s $nick] $configured]
    set line [json_escape $line]
    puts "{\"ok\": true, \"protocol\": \"mediabot-script-v1\", \"actions\": \[{\"type\": \"reply\", \"text\": \"$line\"}, {\"type\": \"log\", \"level\": 3, \"text\": \"greeter.tcl welcomed [json_escape $nick] (configured)\"}\]}"
    exit 0
}

set greetings [list \
    "Welcome aboard, %s! Pull up a chair." \
    "%s has entered the building." \
    "Ah, %s! We were just talking about you. All good things." \
    "Make way — %s is here." \
    "Fresh coffee is on, %s. Probably."]
set line [format [lindex $greetings [expr {int(rand() * [llength $greetings])}]] \
    $nick]
set line [json_escape $line]

puts "{\"ok\": true, \"protocol\": \"mediabot-script-v1\", \"actions\": \[{\"type\": \"reply\", \"text\": \"$line\"}, {\"type\": \"log\", \"level\": 3, \"text\": \"greeter.tcl welcomed [json_escape $nick]\"}\]}"
