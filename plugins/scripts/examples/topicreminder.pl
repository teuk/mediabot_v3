#!/usr/bin/env perl
# =============================================================================
# topicreminder.pl — Mediabot v3 reference plugin script (mediabot-script-v1).
#
# The COMBINED reference: one script using a channel EVENT, a TIMER and
# per-route CONFIG together (mb542) — the three arc features in one file.
# Wire it as an alternative to the simple topicwatch.pl reference:
#
#   EVENTS=topic=examples/topicreminder.pl
#   CONFIG_topic=remind_after=900
#
# Behavior:
#   - event "topic": stay SILENT on IRC (no ack spam), log, and arm one
#     deferred reminder for the channel;
#   - event "timer": deliver the reminder, rebuilt from the ORIGINAL
#     envelope (the snapshot carries data.topic). Two modes (mb546):
#       mode=remind  (default) — re-post the topic as a channel reply;
#       mode=restore           — RE-SET the topic via the mb545 "topic"
#                                action (re-asserts the original topic; it
#                                needs the full triple gate ACTION_MODE=apply
#                                + ALLOW_IRC + ALLOW_TOPIC, otherwise the
#                                apply error stays visible in ".scriptdryrun
#                                last" — a reference script does not hide
#                                its requirements);
#   - a cleared topic (empty) arms nothing;
#   - config remind_after (seconds, 1..3600) adjusts the delay, protocol
#     default 300; invalid values fall back to the default; config mode
#     accepts remind|restore, anything else falls back to remind.
#
# Deliberate limitation worth learning from: the timer name is derived from
# the CHANNEL, and the bridge allows one pending timer per name — so while a
# reminder is pending, further topic changes cannot arm a second one (the
# original reminder wins; the rejected arm is visible as an apply error and
# in the bridge metrics). A reference script exposes that semantic instead
# of hiding it.
#
# Event guardrails (enforced upstream): opt-in route, no self events,
# anti-burst cooldown (you do not see every topic change), channel-scoped
# replies, timer chains rejected.
# =============================================================================

use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);
use Digest::SHA qw(sha1_hex);

use constant DEFAULT_REMIND_AFTER => 300;
use constant MIN_REMIND_AFTER     => 1;
use constant MAX_REMIND_AFTER     => 3600;

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
    : 'someone';
my $topic = (defined $data->{topic} && !ref($data->{topic}))
    ? $data->{topic}
    : '';

# --- per-route configuration (mandatory default, bounded) --------------------
my $config = ref($data->{config}) eq 'HASH' ? $data->{config} : {};

# mb546: delivery mode — remind (reply) or restore (re-set via topic action).
my $mode = 'remind';
if (defined $config->{mode} && !ref($config->{mode})) {
    my $m = lc $config->{mode};
    $mode = $m if $m eq 'remind' || $m eq 'restore';
}

my $remind_after = DEFAULT_REMIND_AFTER;
if (defined $config->{remind_after} && !ref($config->{remind_after})
    && "$config->{remind_after}" =~ /\A[0-9]+\z/) {
    my $configured = int($config->{remind_after});
    $remind_after = $configured
        if $configured >= MIN_REMIND_AFTER && $configured <= MAX_REMIND_AFTER;
}

my @actions;

if ($event eq 'timer') {
    # Deferred run: the snapshot carries the ORIGINAL topic and author.
    if (length $topic) {
        if ($mode eq 'restore') {
            # mb546: re-assert the original topic (needs the triple gate).
            push @actions,
                { type => 'topic', text => $topic },
                { type => 'log', level => 'info',
                  text => "topicreminder: restored topic on $channel (set by $nick)" };
        }
        else {
            push @actions,
                { type => 'reply', text => "topic reminder: $topic (set by $nick)" },
                { type => 'log', level => 'info',
                  text => "topicreminder: re-posted topic on $channel" };
        }
    }
    else {
        push @actions,
            { type => 'log', level => 'info',
              text => "topicreminder: nothing to re-post on $channel" };
    }
}
elsif ($event eq 'topic') {
    if (length $topic) {
        my $channel_key = lc $channel;
        my $safe_channel = $channel_key;
        $safe_channel =~ s/[^A-Za-z0-9_.-]/_/g;
        # mb543-B2: garder un prefixe lisible et un suffixe stable. Une simple
        # substitution/troncature peut faire partager le meme nom a deux canaux.
        my $digest = substr(sha1_hex($channel_key), 0, 10);
        my $prefix_budget = 64 - length('topic_reminder_') - 1 - length($digest);
        my $timer_name = 'topic_reminder_'
            . substr($safe_channel, 0, $prefix_budget)
            . '_' . $digest;
        push @actions,
            { type => 'timer', name => $timer_name, delay => $remind_after },
            { type => 'log', level => 'info',
              text => "topicreminder: armed ${remind_after}s reminder on $channel" };
    }
    else {
        push @actions,
            { type => 'log', level => 'info',
              text => "topicreminder: topic cleared on $channel, nothing armed" };
    }
}
else {
    # Routed to something unexpected: log it, stay silent on IRC.
    push @actions,
        { type => 'log', level => 'warning',
          text => "topicreminder: unexpected event '$event' (route me to topic only)" };
}

# --- emit the contract -------------------------------------------------------
print encode_json({
    protocol => 'mediabot-script-v1',
    ok       => JSON::PP::true,
    actions  => \@actions,
});
