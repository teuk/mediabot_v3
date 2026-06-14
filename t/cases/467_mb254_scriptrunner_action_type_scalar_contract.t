#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use JSON::PP qw(encode_json);
use FindBin qw($Bin);
use lib "$Bin/../..";

use Mediabot::ScriptRunner;

my $runner = Mediabot::ScriptRunner->new(script_dir => 'plugins/scripts', max_actions => 20);

sub decode_ok {
    my ($payload) = @_;
    return $runner->decode_script_response(encode_json($payload));
}

my $valid = decode_ok({ actions => [ { type => 'reply', target => '#teuk', text => 'hello' } ] });
ok($valid->{ok}, 'valid scalar action type remains accepted');
is(scalar @{ $valid->{actions} }, 1, 'valid action is exposed');
is($valid->{actions}[0]{type}, 'reply', 'valid action type normalized');

my $spaced = decode_ok({ actions => [ { type => ' Reply ', target => '#teuk', text => 'hello' } ] });
ok($spaced->{ok}, 'scalar action type with surrounding whitespace is accepted');
is($spaced->{actions}[0]{type}, 'reply', 'spaced scalar action type is trimmed and normalized');

my $array_type = decode_ok({ actions => [ { type => ['reply'], target => '#teuk', text => 'hello' } ] });
ok(!$array_type->{ok}, 'array action type is rejected');
is_deeply($array_type->{actions}, [], 'array action type exposes no actions');
like(join(' ', @{ $array_type->{errors} }), qr/type must be scalar/, 'array action type reports scalar contract error');

my $hash_type = decode_ok({ actions => [ { type => { bad => 'reply' }, target => '#teuk', text => 'hello' } ] });
ok(!$hash_type->{ok}, 'object action type is rejected');
is_deeply($hash_type->{actions}, [], 'object action type exposes no actions');
like(join(' ', @{ $hash_type->{errors} }), qr/type must be scalar/, 'object action type reports scalar contract error');

my $src = do { local $/; open my $fh, '<', 'Mediabot/ScriptRunner.pm' or die $!; <$fh> };
like($src, qr/mb254-B1: keep action type itself in the JSON scalar contract/, 'ScriptRunner source contains mb254 marker');
unlike($src, qr/\bsystem\s*(?:\(| )|\bqx\s*(?:\/|\(|\{)|`[^`]+`/, 'mb254 action type scalar guard does not introduce shell execution');

done_testing();
