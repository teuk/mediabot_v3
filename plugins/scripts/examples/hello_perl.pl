use strict;
use warnings;
use utf8;
use JSON::PP qw(decode_json encode_json);

# mb181-B1: example external Perl script for the Mediabot ScriptRunner protocol.
# It reads a mediabot-script-v1 JSON envelope on STDIN and prints JSON actions
# on STDOUT. The actions are meant to pass through ScriptActionRunner.

my $input = do { local $/; <STDIN> };
my $payload = eval { decode_json($input || '{}') } || {};

my $command = $payload->{data}{command} || 'unknown';
my $channel = $payload->{data}{channel} || $payload->{data}{target} || '';

print encode_json({
    actions => [
        {
            type   => 'reply',
            target => $channel,
            text   => "Perl script bridge OK for command: $command",
        },
        {
            type  => 'log',
            level => 'info',
            text  => 'Perl example script produced a dry-run action plan',
        },
    ],
});
