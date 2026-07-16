#!/usr/bin/env perl
# =============================================================================
# remind.pl — Mediabot v3 reference plugin script (mediabot-script-v1), in Perl.
#
# The reference example for TIMER actions (mb525/mb528), routed as `premind`
# in the sample configuration:
#
#   premind 300 stretch your legs   -> confirms, then pings you 300s later
#   premind 10 tea is ready         -> short kitchen timer
#
# Timer lifecycle demonstrated here:
#   1. event "public_command": validate the input, then emit BOTH a reply
#      (immediate confirmation) and a timer action:
#        { "type": "timer", "name": "remind_<nick>", "delay": N }
#   2. the bridge arms the timer (ACTION_MODE=apply); when it expires, this
#      SAME script is re-run with event "timer". The deferred invocation
#      receives the ORIGINAL data (channel/target/nick/command/args) plus
#      timer_name and timer_delay — that is how the reminder text survives
#      between the two runs: it is rebuilt from the original args.
#   3. event "timer": emit the reminder reply. Deferred output passes through
#      the same ALLOW_IRC and channel-scope guards as immediate output.
#
# Bridge guardrails a timer script must live with (enforced upstream, never
# trusted to the script):
#   - delay is bounded to 1..3600 seconds by protocol validation;
#   - timer names are [A-Za-z0-9_.-], max 64 chars;
#   - one pending timer per name: this script derives the name from the nick,
#     so each nick gets ONE pending reminder (a second `premind` while one is
#     pending is rejected by the bridge, visible in `.scriptdryrun timers`);
#   - a timer-invoked run can never schedule another timer (no chains) —
#     which is why the "timer" branch below only replies and logs.
# =============================================================================

use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);

use constant MIN_DELAY => 1;
use constant MAX_DELAY => 3600;
use constant MAX_TEXT  => 300;

# --- read + parse the envelope ----------------------------------------------
my $raw = do { local $/; <STDIN> };
$raw = '' unless defined $raw;

my $payload = eval { decode_json($raw) };
$payload = {} unless ref($payload) eq 'HASH';

my $event = (defined $payload->{event} && !ref($payload->{event}))
    ? $payload->{event}
    : 'unknown';
my $data = ref($payload->{data}) eq 'HASH' ? $payload->{data} : {};

my $nick = (defined $data->{nick} && !ref($data->{nick}) && length $data->{nick})
    ? $data->{nick}
    : 'someone';
my $command = (defined $data->{command} && !ref($data->{command}) && length $data->{command})
    ? $data->{command}
    : 'remind';
my $args = ref($data->{args}) eq 'ARRAY' ? $data->{args} : [];

# mb532: per-route configuration (mb531). CONFIG_premind=max_delay=1800
# lowers the accepted delay ceiling for this route; the protocol bound
# (3600s) always wins as the hard maximum, and bad values fall back to it.
my $config = ref($data->{config}) eq 'HASH' ? $data->{config} : {};
my $max_delay = MAX_DELAY;
if (defined $config->{max_delay} && !ref($config->{max_delay})
    && "$config->{max_delay}" =~ /\A[0-9]+\z/) {
    my $configured = int($config->{max_delay});
    $max_delay = $configured if $configured >= MIN_DELAY && $configured <= MAX_DELAY;
}

# --- rebuild the reminder text from the original args ------------------------
# args[0] = delay in seconds, the rest is the message. On the "timer" event the
# bridge hands us the ORIGINAL args again, so the same parsing works twice.
my ($delay_arg, @message_words) = grep { defined && !ref } @$args;
my $message = join ' ', grep { length } @message_words;
$message =~ s/^\s+|\s+$//g;
$message = substr($message, 0, MAX_TEXT) if length($message) > MAX_TEXT;

my @actions;

if ($event eq 'timer') {
    # Deferred run: just deliver. Never emit another timer here (chains are
    # rejected upstream anyway).
    my $text = length($message) ? $message : 'time is up';
    push @actions,
        { type => 'reply', text => "$nick: reminder: $text" },
        { type => 'log', level => 'info', text => "remind: delivered to $nick" };
}
else {
    my $delay = (defined $delay_arg && $delay_arg =~ /\A[0-9]+\z/) ? int($delay_arg) : 0;

    if ($delay < MIN_DELAY || $delay > $max_delay || !length($message)) {
        push @actions, {
            type => 'reply',
            text => "$nick: usage: $command <seconds 1-$max_delay> <message>"
                  . " — e.g. $command 300 stretch your legs",
        };
    }
    else {
        # One pending reminder per nick: derive the timer name from the nick,
        # restricted to the protocol charset ([A-Za-z0-9_.-], max 64).
        my $safe_nick = $nick;
        $safe_nick =~ s/[^A-Za-z0-9_.-]/_/g;
        my $timer_name = substr('remind_' . $safe_nick, 0, 64);

        push @actions,
            { type => 'reply', text => "$nick: ok, I will remind you in ${delay}s" },
            { type => 'timer', name => $timer_name, delay => $delay },
            { type => 'log', level => 'info',
              text => "remind: armed $timer_name delay=${delay}s for $nick" };
    }
}

# --- emit the contract -------------------------------------------------------
print encode_json({
    protocol => 'mediabot-script-v1',
    ok       => JSON::PP::true,
    actions  => \@actions,
});
