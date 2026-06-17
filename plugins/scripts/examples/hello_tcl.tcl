# Minimal Tcl reference script for the mediabot-script-v1 protocol.
#
# Keep this dependency-free: Tcl JSON packages are not guaranteed on every bot
# host. This example extracts the simple command field and returns reply/log
# actions. The bridge configuration decides whether they are planned or applied.

set input [read stdin]
set command "unknown"

if {[regexp {"command"[ \t\r\n]*:[ \t\r\n]*"([^"\\]*)"} $input -> extracted_command]} {
    set command $extracted_command
}

proc json_escape {value} {
    return [string map [list \\ \\\\ \" \\\" \n \\n \r \\r \t \\t] $value]
}

set reply_text "Tcl script bridge OK for command: $command"
set log_text "Tcl example script produced an action plan"
set reply_json [json_escape $reply_text]
set log_json [json_escape $log_text]

puts [format {{"protocol":"mediabot-script-v1","ok":true,"actions":[{"type":"reply","text":"%s"},{"type":"log","level":"info","text":"%s"}]}} $reply_json $log_json]
