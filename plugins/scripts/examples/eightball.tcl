# =============================================================================
# eightball.tcl — Mediabot v3 reference plugin script (mediabot-script-v1), Tcl.
#
# A useful Tcl Magic 8-Ball example routed as `p8ball` in the sample
# configuration. The alias preserves Mediabot's language-aware built-in `8ball`.
#
#   p8ball will it rain today?   -> picks a random fortune-teller answer
#   p8ball                       -> asks the user for a question
#
# It demonstrates what a real Tcl plugin needs WITHOUT any JSON package:
#   - read the mediabot-script-v1 JSON envelope on STDIN;
#   - extract simple fields (nick) and the words of the args array with plain
#     regexp (the class [^"\\]* stops at a quote/backslash, consistent with
#     hello_tcl.tcl) -- fine for nicks and plain-word questions; for exotic
#     input a real JSON parser (tcllib's json) is recommended;
#   - escape reply/log text correctly for JSON output;
#   - emit an explicit "ok" + "protocol", a reply action (no target -> defaults
#     to the originating channel) and a log action.
#
# Dependency-free (Tcl core only).  Validate on a host with tclsh.
# =============================================================================

set input [read stdin]

# --- minimal JSON string escaper --------------------------------------------
proc json_escape {value} {
    return [string map [list \\ \\\\ \" \\\" \n \\n \r \\r \t \\t] $value]
}

# --- minimal field extraction (no JSON parser) -------------------------------
set command "8ball"
if {[regexp {"command"[ \t\r\n]*:[ \t\r\n]*"([^"\\]*)"} $input -> extracted_command]} {
    if {$extracted_command ne ""} {
        set command $extracted_command
    }
}

set nick "someone"
if {[regexp {"nick"[ \t\r\n]*:[ \t\r\n]*"([^"\\]*)"} $input -> extracted_nick]} {
    if {$extracted_nick ne ""} {
        set nick $extracted_nick
    }
}

# Join the words of the "args" array into the question. This dependency-free
# parser accepts the simple scalar args emitted by ScriptRunner; use tcllib json
# for a general-purpose JSON parser.
set question ""
if {[regexp {"args"[ \t\r\n]*:[ \t\r\n]*\[([^]]*)\]} $input -> args_body]} {
    set parts {}
    foreach {whole word} [regexp -all -inline {"([^"\\]*)"} $args_body] {
        lappend parts $word
    }
    set question [string trim [join $parts " "]]
}

# --- the classic Magic 8-Ball answers (nested braces => one element each) -----
set answers {
    {It is certain.}
    {Without a doubt.}
    {Yes, definitely.}
    {You may rely on it.}
    {Most likely.}
    {Outlook good.}
    {Signs point to yes.}
    {Reply hazy, try again.}
    {Ask again later.}
    {Better not tell you now.}
    {Cannot predict now.}
    {Concentrate and ask again.}
    {Don't count on it.}
    {My reply is no.}
    {My sources say no.}
    {Outlook not so good.}
    {Very doubtful.}
}

if {$question eq ""} {
    set reply "$nick: ask me a yes/no question first, e.g. $command will it rain today?"
    set logmsg "8ball: $nick asked with no question"
} else {
    set answer [lindex $answers [expr {int(rand() * [llength $answers])}]]
    set reply "$nick asked: $question -- the 8-ball says: $answer"
    set logmsg "8ball: answered $nick"
}

set reply_json [json_escape $reply]
set log_json [json_escape $logmsg]

puts [format {{"protocol":"mediabot-script-v1","ok":true,"actions":[{"type":"reply","text":"%s"},{"type":"log","level":"info","text":"%s"}]}} $reply_json $log_json]
