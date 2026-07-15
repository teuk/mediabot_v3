#!/usr/bin/env perl
# =============================================================================
# topicwatch.pl — Mediabot v3 reference plugin script (mediabot-script-v1).
#
# The reference example for the `topic` event route (mb529/mb530), wired in
# the sample configuration as:
#
#   EVENTS=topic=examples/topicwatch.pl
#
# When the topic changes on a routed channel, the bridge re-runs this script
# with event "topic"; the envelope carries channel/nick and the NEW topic in
# the dedicated `topic` field. This script acknowledges the change in the
# channel and keeps a log trail.
#
# It demonstrates the event-specific envelope fields (compare with greet.pl,
# which uses ident/host on `join`; a `part` route would receive the part
# reason in `message`). Untrusted text (the topic) is passed straight into
# the reply: JSON::PP escapes it in the emitted contract and the bridge
# bounds reply length upstream — a reference script should not re-implement
# either.
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
my $topic = (defined $data->{topic} && !ref($data->{topic}))
    ? $data->{topic}
    : '';

my @actions;

if ($event eq 'topic') {
    my $shown = length($topic) ? $topic : '(cleared)';
    push @actions,
        { type => 'reply', text => "topic set by $nick: $shown" },
        { type => 'log', level => 'info', text => "topicwatch: $nick changed the topic" };
}
else {
    push @actions,
        { type => 'log', level => 'warning',
          text => "topicwatch: unexpected event '$event' (route me to topic only)" };
}

# --- emit the contract -------------------------------------------------------
print encode_json({
    protocol => 'mediabot-script-v1',
    ok       => JSON::PP::true,
    actions  => \@actions,
});
