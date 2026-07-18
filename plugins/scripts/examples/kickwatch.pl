#!/usr/bin/env perl
# =============================================================================
# kickwatch.pl — Mediabot v3 reference plugin script (mediabot-script-v1).
#
# The reference example for the `kick` event route (mb535), wired in the
# sample configuration as:
#
#   EVENTS=kick=examples/kickwatch.pl
#
# When someone is kicked from a routed channel, the bridge re-runs this script
# with event "kick". The envelope carries the kick-specific fields:
#   nick    -> who performed the kick (the operator)
#   kicked  -> who was kicked (the victim)
#   message -> the kick reason (may be empty)
# plus the usual channel/target. This script leaves a public trace of the
# moderation action in the SAME channel and a log line for the operator.
#
# Event guardrails (enforced upstream): opt-in EVENTS route only; when the
# bot itself is the kicker OR the victim the event never reaches scripts;
# anti-burst cooldown per event/channel (a mass-kick sweep is mostly counted
# and ignored — never assume this script sees every kick); replies cannot
# target another channel. When routed to an unexpected event this script logs
# a warning and stays silent on IRC.
# =============================================================================

use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);

# --- read + parse the envelope ----------------------------------------------
my $raw = do { local $/; <STDIN> };
$raw = '' unless defined $raw;

my $payload = eval { decode_json($raw) };
$payload = {} unless ref($payload) eq 'HASH';

my $event = (defined $payload->{event} && !ref($payload->{event}))
    ? $payload->{event}
    : 'unknown';
my $data = ref($payload->{data}) eq 'HASH' ? $payload->{data} : {};

my $kicker = (defined $data->{nick} && !ref($data->{nick}) && length $data->{nick})
    ? $data->{nick}
    : 'someone';
my $kicked = (defined $data->{kicked} && !ref($data->{kicked}) && length $data->{kicked})
    ? $data->{kicked}
    : 'someone';
my $reason = (defined $data->{message} && !ref($data->{message}))
    ? $data->{message}
    : '';

my @actions;

if ($event eq 'kick') {
    my $text = "$kicked was shown the door by $kicker";
    $text .= " (\"$reason\")" if length $reason;
    push @actions,
        { type => 'reply', text => $text },
        { type => 'log', level => 'info',
          text => "kickwatch: $kicker kicked $kicked" };
}
else {
    # Routed to something unexpected: log it, stay silent on IRC.
    push @actions,
        { type => 'log', level => 'warning',
          text => "kickwatch: unexpected event '$event' (route me to kick only)" };
}

# --- emit the contract -------------------------------------------------------
print encode_json({
    protocol => 'mediabot-script-v1',
    ok       => JSON::PP::true,
    actions  => \@actions,
});
