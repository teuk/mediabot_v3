#!/usr/bin/env perl
# =============================================================================
# gatekeeper.pl — Mediabot v3 reference plugin script (mediabot-script-v1).
#
# The canonical use of the kick action (mb554): join-time gatekeeping. Route:
#
#   EVENTS=join=examples/gatekeeper.pl
#   CONFIG_join=kick_substrings=spambot flood;kick_reason=not welcome here
#
# Behavior:
#   - event "join": if the joining nick contains one of the configured
#     substrings (case-insensitive, space-separated list), emit a kick
#     action with the configured reason; otherwise emit NOTHING on IRC —
#     normal joins must stay silent (route greet.pl too if you want
#     greetings; two routes cannot share one event, pick per channel need).
#   - kick_substrings has NO default: an empty or absent configuration
#     means the gate is open and the script never kicks anyone. A guard
#     this sharp must be armed explicitly, twice (the config AND the
#     ALLOW_KICK gate).
#   - matching is substring-based on purpose: no user-supplied regex, no
#     ReDoS surface, no surprise semantics.
#
# Applying the kick needs the full gate chain: ACTION_MODE=apply +
# ALLOW_IRC=yes + ALLOW_KICK=yes. Without ALLOW_KICK the run shows the
# dedicated apply error in ".scriptdryrun last" — a reference script
# advertises its requirements. The bridge refuses to kick the bot itself,
# and is_self join events never reach scripts anyway.
# =============================================================================

use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);
use Encode qw(encode);

# --- read + parse the envelope ----------------------------------------------
my $raw = do { local $/; <STDIN> };
$raw = '' unless defined $raw;

my $payload = eval { decode_json($raw) };
$payload = {} unless ref($payload) eq 'HASH';

my $event = (defined $payload->{event} && !ref($payload->{event}))
    ? $payload->{event}
    : 'unknown';
my $data = ref($payload->{data}) eq 'HASH' ? $payload->{data} : {};

my $channel = (defined $data->{channel} && !ref($data->{channel}) && length $data->{channel})
    ? $data->{channel}
    : '';
my $nick = (defined $data->{nick} && !ref($data->{nick}) && length $data->{nick})
    ? $data->{nick}
    : '';

# --- per-route configuration (no default pattern: unarmed means open) --------
my $config = ref($data->{config}) eq 'HASH' ? $data->{config} : {};

my @substrings;
if (defined $config->{kick_substrings} && !ref($config->{kick_substrings})) {
    @substrings = grep { length } split /\s+/, lc "$config->{kick_substrings}";
}

my $reason = 'not welcome';
if (defined $config->{kick_reason} && !ref($config->{kick_reason})
    && length "$config->{kick_reason}") {
    $reason = "$config->{kick_reason}";
    chop $reason while length(encode('UTF-8', $reason)) > 120;
}

my @actions;

if ($event eq 'join') {
    my $lc_nick = lc $nick;
    my ($hit) = grep { index($lc_nick, $_) >= 0 } @substrings;

    if (length($nick) && defined $hit) {
        push @actions,
            { type => 'kick', nick => $nick, reason => $reason },
            { type => 'log', level => 'info',
              text => "gatekeeper: kick requested for $nick from $channel (matched '$hit')" };
    }
    # No match (or unarmed config): total silence — a gatekeeper that
    # comments every visitor is a nuisance, not a guard.
}
else {
    push @actions,
        { type => 'log', level => 'warning',
          text => "gatekeeper: unexpected event '$event' (route me to join only)" };
}

# --- emit the contract -------------------------------------------------------
print encode_json({
    protocol => 'mediabot-script-v1',
    ok       => JSON::PP::true,
    actions  => \@actions,
});
