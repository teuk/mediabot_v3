package require json
package require json::write
fconfigure stdin -encoding utf-8
fconfigure stdout -encoding utf-8

set request [json::json2dict [read stdin]]
set data [dict get $request data]
set arguments [dict get $data args]
set links [dict create \
    docs https://github.com/teuk/mediabot_v3 \
    wiki https://github.com/teuk/mediabot_v3/wiki \
    issues https://github.com/teuk/mediabot_v3/issues]

set key [string tolower [lindex $arguments 0]]
if {[llength $arguments] == 1 && [dict exists $links $key]} {
    set text [dict get $links $key]
} else {
    set text "Usage : plien <docs|wiki|issues>"
}

set notice [json::write object \
    type [json::write string notice] \
    target [json::write string [dict get $data nick]] \
    text [json::write string $text]]
puts [json::write object protocol [json::write string mediabot-script-v1] \
    ok true actions [json::write array $notice]]
