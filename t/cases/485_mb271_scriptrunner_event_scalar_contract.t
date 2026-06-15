#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);

use lib '.';
use Mediabot::ScriptRunner;

my $tmp = tempdir(CLEANUP => 1);
my $scripts = "$tmp/plugins/scripts";
mkdir "$tmp/plugins" or die "mkdir plugins: $!";
mkdir $scripts or die "mkdir scripts: $!";

my $runner = Mediabot::ScriptRunner->new(script_dir => $scripts);

my $valid = $runner->build_event_payload('public_command', command => 'hello');
is($valid->{event}, 'public_command', 'valid scalar event is preserved');

my $trimmed = $runner->build_event_payload('  public_command  ', command => 'hello');
is($trimmed->{event}, 'public_command', 'scalar event is trimmed');

my $missing = $runner->build_event_payload(undef, command => 'hello');
is($missing->{event}, 'unknown', 'missing event falls back to unknown');

my $array_event = $runner->build_event_payload([ 'public_command' ], command => 'hello');
is($array_event->{event}, 'unknown', 'ARRAY event falls back to unknown');

my $hash_event = $runner->build_event_payload({ bad => 1 }, command => 'hello');
is($hash_event->{event}, 'unknown', 'HASH event falls back to unknown');

my $space_event = $runner->build_event_payload('public command', command => 'hello');
is($space_event->{event}, 'unknown', 'event containing whitespace is rejected');

my $newline_event = $runner->build_event_payload("public\ncommand", command => 'hello');
is($newline_event->{event}, 'unknown', 'event containing newline is rejected');

my $encoded = $runner->encode_event_payload($array_event);
my $decoded = decode_json($encoded);
is($decoded->{event}, 'unknown', 'encoded JSON event never contains an ARRAY ref');

my $plan = $runner->run_dry('examples/future.pl', [ 'bad' ], command => 'hello');
ok($plan->{ok}, 'run_dry still builds a plan for a future valid script path');
my $stdin = decode_json($plan->{stdin});
is($stdin->{event}, 'unknown', 'run_dry sanitizes non-scalar event before stdin JSON');
is(ref($stdin->{event}), '', 'stdin JSON event is scalar');

my $src = do { local (@ARGV, $/) = ('Mediabot/ScriptRunner.pm'); <> };
like($src, qr/mb271-B1/, 'ScriptRunner source contains mb271 event scalar marker');
unlike($src, qr/\b(system|qx)\s*(?:\(|\/|\{)/, 'mb271 event guard does not introduce shell execution');

done_testing();
