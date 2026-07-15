#!/usr/bin/env perl
# =============================================================================
# greet.pl — Mediabot v3 reference plugin script (mediabot-script-v1), in Perl.
#
# The reference example for CHANNEL EVENT routes (mb529/mb530), wired to the
# `join` event in the sample configuration:
#
#   EVENTS=join=examples/greet.pl
#
# When someone joins a routed channel, the bridge re-runs this script with
# event "join" and an envelope carrying channel/nick (+ ident/host). The
# script replies with a short welcome in the SAME channel.
#
# Event guardrails a join script must live with (enforced upstream, never
# trusted to the script):
#   - opt-in only: without an EVENTS route this script never runs;
#   - the bot's own join never triggers scripts;
#   - anti-burst cooldown: at most one run per event per channel per
#     EVENT_COOLDOWN window (default 10s) — during a netsplit rejoin wave,
#     most joins are counted and ignored, so DO NOT design a join script
#     that assumes it sees every single join;
#   - replies default to the originating channel and cannot target another
#     channel (channel-scope guard).
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

my $nick = (defined $data->{nick} && !ref($data->{nick}) && length $data->{nick})
    ? $data->{nick}
    : 'someone';
my $channel = (defined $data->{channel} && !ref($data->{channel}) && length $data->{channel})
    ? $data->{channel}
    : '';

my @actions;

if ($event eq 'join') {
    # mb531: per-route configuration. With CONFIG_join=welcome=Bienvenue the
    # envelope carries data.config.welcome; scripts always keep a default.
    my $config  = ref($data->{config}) eq 'HASH' ? $data->{config} : {};
    my $welcome = (defined $config->{welcome} && !ref($config->{welcome}) && length $config->{welcome})
        ? $config->{welcome}
        : "welcome to $channel,";
    push @actions,
        { type => 'reply', text => "$welcome $nick!" },
        { type => 'log', level => 'info', text => "greet: welcomed $nick on $channel" };
}
else {
    # Routed to something unexpected: log it, stay silent on IRC. A reference
    # event script should never spam a channel because of a config mistake.
    push @actions,
        { type => 'log', level => 'warning',
          text => "greet: unexpected event '$event' (route me to join only)" };
}

# --- emit the contract -------------------------------------------------------
print encode_json({
    protocol => 'mediabot-script-v1',
    ok       => JSON::PP::true,
    actions  => \@actions,
});
