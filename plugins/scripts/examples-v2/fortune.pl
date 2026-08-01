#!/usr/bin/env perl
# =============================================================================
# fortune.pl — Mediabot v3 plugin-v2 example script (mediabot-script-v1), Perl.
#
# The v2 twist: this script does NOT need a route in the configuration. Its
# commands are declared in the SIDECAR manifest next to it
# (fortune.pl.manifest.json) and mounted by the PluginManager:
#
#   .plugins loadscript examples-v2/fortune.pl        (partyline, Owner)
#
#   fortune              -> one random aphorism
#   fortune <category>   -> one from that category (code|irc|life)
#   fortunes             -> lists the categories — declared level "Master" in
#                           the sidecar: the auth bridge refuses lower levels
#                           BEFORE this script is even executed.
#
# Everything else is plain mediabot-script-v1, same as examples/: envelope on
# STDIN, explicit ok + protocol, reply/log actions, JSON::PP does the escaping.
# =============================================================================

use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);

my $raw = do { local $/; <STDIN> };
my $env = eval { decode_json($raw) };
$env = {} unless ref($env) eq 'HASH';

my $data    = ref($env->{data}) eq 'HASH' ? $env->{data} : {};
my $command = defined $data->{command} ? lc $data->{command} : 'fortune';
my @args    = ref($data->{args}) eq 'ARRAY' ? @{ $data->{args} } : ();

my %pool = (
    code => [
        'A test you did not run is a bug you scheduled for later.',
        'The fastest query is the one an index answered.',
        'Refactor when it hurts twice, not when it itches once.',
    ],
    irc  => [
        'A netsplit heals faster than a flamewar.',
        'The quietest op is usually the one holding the banlist.',
        'Never /amsg. The channels remember.',
    ],
    life => [
        'Coffee first. Decisions second.',
        'The best time to backup was yesterday; the second best is now.',
        'Slow is smooth, smooth is fast.',
    ],
);

my @actions;

if ($command eq 'fortunes') {
    # Only reachable by Master or better: the sidecar declares this command
    # with level "Master" and the bot refuses lower levels before running us.
    my $cats = join(', ', sort keys %pool);
    push @actions, { type => 'reply', text => "Fortune categories: $cats" };
}
else {
    my $cat = @args && exists $pool{ lc $args[0] } ? lc $args[0] : undef;
    my @from = $cat ? @{ $pool{$cat} }
                    : map { @$_ } values %pool;
    my $pick = $from[ int(rand(@from)) ];
    push @actions, { type => 'reply', text => $pick };
}
push @actions, { type => 'log', level => 3,
                 text => "fortune.pl served '$command'" };

print encode_json({
    ok       => JSON::PP::true,
    protocol => 'mediabot-script-v1',
    actions  => \@actions,
});
