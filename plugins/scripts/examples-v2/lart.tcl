# =============================================================================
# lart.tcl — Mediabot v3 plugin-v2 example script (mediabot-script-v1), Tcl.
#
# A Luser Attitude Readjustment Tool, in loving memory of every Eggdrop that
# ever ran one. Declared by its sidecar (lart.tcl.manifest.json), mounted with:
#
#   .plugins loadscript examples-v2/lart.tcl           (partyline, Owner)
#
#   lart <nick>   -> administers a percussive attitude readjustment
#   lart          -> the tool turns on the person holding it
#
# Dependency-free Tcl core only, same minimal-envelope technique as
# examples/eightball.tcl: plain regexp field extraction (fine for nicks and
# words; use tcllib json for exotic input) and a hand-rolled JSON escaper.
# =============================================================================

set input [read stdin]

proc json_escape {value} {
    return [string map [list \\ \\\\ \" \\\" \n \\n \r \\r \t \\t] $value]
}

set nick "someone"
if {[regexp {"nick"[ \t\r\n]*:[ \t\r\n]*"([^"\\]*)"} $input -> extracted_nick]} {
    if {$extracted_nick ne ""} {
        set nick $extracted_nick
    }
}

# First word of the args array = the target. Plain-word extraction, capped.
set target ""
if {[regexp {"args"[ \t\r\n]*:[ \t\r\n]*\[[ \t\r\n]*"([^"\\]*)"} $input -> first_arg]} {
    set target [string range $first_arg 0 29]
}
if {$target eq ""} {
    set target $nick
}

set tools [list \
    "a large trout" \
    "the collected RFC printouts, hardcover" \
    "a SCSI terminator (still terminated)" \
    "an unbalanced ircd.conf" \
    "volume 2 of the sendmail manual"]
set tool [lindex $tools [expr {int(rand() * [llength $tools])}]]

set reply "readjusts [json_escape $target]'s attitude with [json_escape $tool]."
set log_text "lart.tcl readjusted [json_escape $target]"

puts "{\"ok\": true, \"protocol\": \"mediabot-script-v1\", \"actions\": \[{\"type\": \"reply\", \"text\": \"$reply\"}, {\"type\": \"log\", \"level\": 3, \"text\": \"$log_text\"}\]}"
