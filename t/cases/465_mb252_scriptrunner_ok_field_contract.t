#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use Test::More;
use JSON::PP qw(encode_json);

use lib '.';
use Mediabot::ScriptRunner;

my $runner = Mediabot::ScriptRunner->new(script_dir => 'plugins/scripts');

sub sample_actions {
    return [
        {
            type => 'log',
            text => 'ok field contract test',
        }
    ];
}

sub decode_response {
    my ($payload) = @_;
    return $runner->decode_script_response(encode_json($payload));
}

my $absent = decode_response({ actions => sample_actions() });
ok($absent->{ok}, 'legacy response without ok remains accepted');
is(scalar @{ $absent->{actions} || [] }, 1, 'legacy response still exposes actions');

my $bool_true = decode_response({ ok => JSON::PP::true, actions => sample_actions() });
ok($bool_true->{ok}, 'JSON boolean true is accepted');
is(scalar @{ $bool_true->{actions} || [] }, 1, 'JSON boolean true exposes actions');

my $num_true = decode_response({ ok => 1, actions => sample_actions() });
ok($num_true->{ok}, 'numeric ok=1 is accepted for legacy scripts');
is(scalar @{ $num_true->{actions} || [] }, 1, 'numeric ok=1 exposes actions');

my $bool_false = decode_response({ ok => JSON::PP::false, errors => ['refused'], actions => sample_actions() });
ok(!$bool_false->{ok}, 'JSON boolean false is rejected');
is_deeply($bool_false->{actions}, [], 'JSON boolean false exposes no actions');
like(join(' ', @{ $bool_false->{errors} || [] }), qr/refused/, 'JSON boolean false preserves bounded error');

my $num_false = decode_response({ ok => 0, errors => ['numeric refused'], actions => sample_actions() });
ok(!$num_false->{ok}, 'numeric ok=0 is rejected');
is_deeply($num_false->{actions}, [], 'numeric ok=0 exposes no actions');
like(join(' ', @{ $num_false->{errors} || [] }), qr/numeric refused/, 'numeric ok=0 preserves bounded error');

for my $case (
    [ 'string true',  { ok => 'true', actions => sample_actions() } ],
    [ 'string false', { ok => 'false', actions => sample_actions() } ],
    [ 'array ok',     { ok => [1], actions => sample_actions() } ],
    [ 'object ok',    { ok => { value => 1 }, actions => sample_actions() } ],
) {
    my ($label, $payload) = @$case;
    my $res = decode_response($payload);
    ok(!$res->{ok}, "$label is rejected as invalid ok field");
    is_deeply($res->{actions}, [], "$label exposes no actions");
    like(join(' ', @{ $res->{errors} || [] }), qr/ok must be a JSON boolean or 0\/1 scalar/, "$label reports explicit contract error");
}

my $source = do {
    open my $fh, '<', 'Mediabot/ScriptRunner.pm' or die "cannot read ScriptRunner.pm: $!";
    local $/;
    <$fh>;
};

like($source, qr/mb252-B1/, 'ScriptRunner source contains mb252 ok field marker');
unlike($source, qr/\bsystem\s*(?:\(| )|\bqx\s*(?:\/|\(|\{)|`[^`]+`/, 'mb252 ok field guard does not introduce shell execution');

done_testing();
