package require json
package require json::write

fconfigure stdin -encoding utf-8
fconfigure stdout -encoding utf-8

set request [json::json2dict [read stdin]]
set data [dict get $request data]
set config [dict get $data config]
set arguments [dict get $data args]
set contact [dict get $config contact]
set hours [dict get $config hours]

set text {Usage : v3permanence [contact|horaires]}
if {[llength $arguments] == 0} {
    set text "Permanence : $contact. Horaires : $hours."
} elseif {[llength $arguments] == 1} {
    switch -- [lindex $arguments 0] {
        contact { set text "Contact : $contact." }
        horaires { set text "Horaires : $hours." }
    }
}

set notice [json::write object type [json::write string notice] \
    text [json::write string $text]]
puts [json::write object protocol [json::write string mediabot-script-v1] \
    ok true actions [json::write array $notice]]
