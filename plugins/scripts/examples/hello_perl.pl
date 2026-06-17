#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use JSON::PP qw(decode_json encode_json);

# Minimal Perl reference script for the mediabot-script-v1 protocol.
#
# It reads one JSON object from STDIN and returns reply/log actions on STDOUT.
# The script does not decide whether those actions are only planned or really
# applied: ACTION_MODE, ALLOW_IRC and APPLY_REQUIRE_SCOPE belong to the trusted
# Mediabot bridge configuration.

my $input = do { local $/; <STDIN> };
my $payload = eval { decode_json($input || '{}') };
$payload = {} unless ref($payload) eq 'HASH';

my $data = ref($payload->{data}) eq 'HASH' ? $payload->{data} : {};
my $command = defined($data->{command}) && !ref($data->{command}) && length($data->{command})
    ? $data->{command}
    : 'unknown';
my $channel = defined($data->{channel}) && !ref($data->{channel}) && length($data->{channel})
    ? $data->{channel}
    : (defined($data->{target}) && !ref($data->{target}) ? $data->{target} : '');

print encode_json({
    protocol => 'mediabot-script-v1',
    ok       => JSON::PP::true,
    actions  => [
        {
            type   => 'reply',
            target => $channel,
            text   => "Perl script bridge OK for command: $command",
        },
        {
            type  => 'log',
            level => 'info',
            text  => 'Perl example script produced an action plan',
        },
    ],
});
