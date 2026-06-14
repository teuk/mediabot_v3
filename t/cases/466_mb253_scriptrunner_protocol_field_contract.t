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
            text => 'protocol contract test',
        }
    ];
}

sub decode_response {
    my ($payload) = @_;
    return $runner->decode_script_response(encode_json($payload));
}

my $legacy = decode_response({ ok => 1, actions => sample_actions() });
ok($legacy->{ok}, 'legacy response without protocol remains accepted');
is(scalar @{ $legacy->{actions} || [] }, 1, 'legacy response without protocol still exposes actions');

my $declared = decode_response({ protocol => 'mediabot-script-v1', ok => 1, actions => sample_actions() });
ok($declared->{ok}, 'declared mediabot-script-v1 protocol is accepted');
is(scalar @{ $declared->{actions} || [] }, 1, 'declared protocol exposes actions');

my $trimmed = decode_response({ protocol => '  mediabot-script-v1  ', ok => 1, actions => sample_actions() });
ok($trimmed->{ok}, 'declared protocol is trimmed before validation');

for my $case (
    [ 'wrong protocol', { protocol => 'mediabot-script-v2', ok => 1, actions => sample_actions() }, qr/unsupported script response protocol/ ],
    [ 'empty protocol', { protocol => '', ok => 1, actions => sample_actions() }, qr/unsupported script response protocol/ ],
    [ 'array protocol', { protocol => ['mediabot-script-v1'], ok => 1, actions => sample_actions() }, qr/protocol must be scalar/ ],
    [ 'object protocol', { protocol => { name => 'mediabot-script-v1' }, ok => 1, actions => sample_actions() }, qr/protocol must be scalar/ ],
) {
    my ($label, $payload, $re) = @$case;
    my $res = decode_response($payload);
    ok(!$res->{ok}, "$label is rejected");
    is_deeply($res->{actions}, [], "$label exposes no actions");
    like(join(' ', @{ $res->{errors} || [] }), $re, "$label reports explicit protocol error");
}

my $declared_failure = decode_response({ protocol => 'mediabot-script-v1', ok => 0, errors => ['refused'], actions => sample_actions() });
ok(!$declared_failure->{ok}, 'declared protocol still respects ok=false');
is_deeply($declared_failure->{actions}, [], 'declared ok=false exposes no actions');
like(join(' ', @{ $declared_failure->{errors} || [] }), qr/refused/, 'declared ok=false preserves failure reason');

my $source = do {
    open my $fh, '<', 'Mediabot/ScriptRunner.pm' or die "cannot read ScriptRunner.pm: $!";
    local $/;
    <$fh>;
};

like($source, qr/mb253-B1/, 'ScriptRunner source contains mb253 protocol marker');
unlike($source, qr/`[^`]+`|\bqx\s*(?:\/|\(|\{)|\bsystem\s*(?:\(| )/, 'mb253 protocol guard does not introduce shell execution');

done_testing();
