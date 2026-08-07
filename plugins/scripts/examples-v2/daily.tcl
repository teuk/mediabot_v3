# =============================================================================
# daily.tcl — Mediabot v3 plugin-v2 CRON example (mediabot-script-v1), Tcl.
#
# Three mb599/mb600/mb601 mechanisms in one small script: a periodic event,
# operator configuration, and persistent state.
#
#   .plugins loadscript examples-v2/daily.tcl          (partyline, Owner)
#
#   # in the bot conf, section [plugins]:
#   daily.CHANNEL="#quebec"
#   daily.HOUR="9"
#   daily.TEXT="Good morning! The cider is cold and the logs are rotated."
#
# plugin_cron_observed fires once a minute (Eggdrop bind time, reborn) and
# YOUR script decides whether this minute matters: every other minute we
# succeed with zero actions (cookbook pattern 6).
#
# Two subtleties worth stealing:
#   * a cron event belongs to no channel, so the reply carries an EXPLICIT
#     target taken from the configuration — there is no channel context to
#     default to;
#   * the last announced day is kept in data.storage, so a restart (or a
#     second tick inside the same minute) never announces twice.
# =============================================================================

set input [read stdin]

proc json_escape {value} {
    return [string map [list \\ \\\\ \" \\\" \n \\n \r \\r \t \\t] $value]
}

proc field {input name} {
    if {[regexp "\"$name\"\[ \\t\\r\\n\]*:\[ \\t\\r\\n\]*\"(\[^\"\\\\\]*)\"" $input -> value]} {
        return $value
    }
    if {[regexp "\"$name\"\[ \\t\\r\\n\]*:\[ \\t\\r\\n\]*(\[0-9\]+)" $input -> value]} {
        return $value
    }
    return ""
}

proc silence {} {
    puts "{\"ok\": true, \"protocol\": \"mediabot-script-v1\", \"actions\": \[\]}"
    exit 0
}

set channel [field $input CHANNEL]
set text    [field $input TEXT]
if {$channel eq "" || $text eq ""} { silence }

set want_hour   [field $input HOUR]
set want_minute [field $input MINUTE]
if {$want_hour eq ""}   { set want_hour 9 }
if {$want_minute eq ""} { set want_minute 0 }

set hour   [field $input hour]
set minute [field $input minute]
if {$hour eq "" || $minute eq ""} { silence }

# Not our minute: succeed quietly. This is the common case, once a minute,
# all day long — keep it cheap and silent.
if {int($hour) != int($want_hour) || int($minute) != int($want_minute)} { silence }

# Our minute, but did we already speak today? data.storage is read fresh at
# every dispatch, so this survives a restart.
set year  [field $input year]
set month [field $input month]
set mday  [field $input mday]
if {$year eq "" || $month eq "" || $mday eq ""} { silence }
set today "$year-$month-$mday"
if {[field $input last] eq $today} { silence }

set line [json_escape $text]
set target [json_escape $channel]
puts "{\"ok\": true, \"protocol\": \"mediabot-script-v1\", \"actions\": \[{\"type\": \"store\", \"data\": {\"last\": \"[json_escape $today]\"}}, {\"type\": \"reply\", \"target\": \"$target\", \"text\": \"$line\"}, {\"type\": \"log\", \"level\": 3, \"text\": \"daily.tcl announced for $today\"}\]}"
