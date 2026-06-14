# mb198-B1: example external Tcl script for the Mediabot ScriptRunner protocol.
#
# Keep this dependency-free.  Tcl JSON packages are not guaranteed to be present
# on every minimal bot host, so this demo extracts only the simple command field
# from the mediabot-script-v1 JSON envelope and emits a valid JSON action list.

set input [read stdin]
set command "unknown"

if {[regexp {"command"[ \t\r\n]*:[ \t\r\n]*"([^"\\]*)"} $input -> extracted_command]} {
    set command $extracted_command
}

proc json_escape {value} {
    return [string map [list \\\\ \\\\\\\\ \" \\\" \n \\n \r \\r \t \\t] $value]
}

set reply_text "Tcl script bridge OK for command: $command"
set log_text "Tcl example script produced a dry-run action plan"
set reply_json [json_escape $reply_text]
set log_json [json_escape $log_text]

puts [format {{"actions":[{"type":"reply","text":"%s"},{"type":"log","level":"info","text":"%s"}]}} $reply_json $log_json]
