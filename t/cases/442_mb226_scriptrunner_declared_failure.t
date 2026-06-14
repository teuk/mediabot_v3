#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use FindBin qw($Bin);
use lib "$Bin/../..";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP qw(encode_json);

use Mediabot::ScriptRunner;
use Mediabot::ScriptActionRunner;

my $tmp = tempdir(CLEANUP => 1);
my $scripts = "$tmp/scripts";
make_path($scripts);

sub write_script226 {
    my ($name, $body) = @_;
    my $path = "$scripts/$name";
    open my $fh, '>', $path or die "cannot write $path: $!";
    print {$fh} $body;
    close $fh;
    chmod 0755, $path;
    return $name;
}

my $runner = Mediabot::ScriptRunner->new(script_dir => $scripts, timeout => 2);
my $actions = Mediabot::ScriptActionRunner->new();

my $failing = write_script226('declared_fail.pl', <<'PL');
use strict;
use warnings;
use JSON::PP qw(encode_json);
print encode_json({
    ok => 0,
    errors => [ 'script refused this command' ],
    actions => [ { type => 'reply', text => 'MUST NOT BE PLANNED' } ],
});
PL

my $result = $runner->run_script($failing, 'public_command', channel => '#test', command => 'failme');
ok(ref($result) eq 'HASH', 'declared failure returns a structured result');
ok(!$result->{ok}, 'declared ok=false makes ScriptRunner result fail');
ok(!$result->{timeout}, 'declared failure is not a timeout');
ok(ref($result->{response}) eq 'HASH', 'declared failure has response hash');
ok(!$result->{response}{ok}, 'decoded response keeps failure state');
is_deeply($result->{response}{actions}, [], 'declared failure exposes no actions');
like(join(' ', @{ $result->{response}{errors} || [] }), qr/script refused this command/, 'declared failure preserves script error');

my $plan = $actions->apply_actions($result, { channel => '#test' }, apply => 1, allow_irc => 1);
ok(!$plan->{ok}, 'declared failure is rejected by action planner');
is_deeply($plan->{planned}, [], 'declared failure plans no actions');
like(join(' ', map { $_->{error} || '' } @{ $plan->{errors} || [] }), qr/script refused this command/, 'action planner preserves declared failure reason');

my $legacy_ok = $runner->decode_script_response(encode_json({
    actions => [ { type => 'reply', text => 'legacy remains valid' } ],
}));
ok($legacy_ok->{ok}, 'legacy response without ok still succeeds when actions are valid');
is(scalar @{ $legacy_ok->{actions} }, 1, 'legacy response still exposes valid action');

my $explicit_errors = $runner->decode_script_response(encode_json({
    ok => 1,
    errors => [ 'explicit error list wins' ],
    actions => [ { type => 'reply', text => 'MUST NOT BE PLANNED' } ],
}));
ok(!$explicit_errors->{ok}, 'non-empty script errors fail even with ok=true');
is_deeply($explicit_errors->{actions}, [], 'script errors expose no actions');

my $source = do {
    open my $fh, '<', "$Bin/../../Mediabot/ScriptRunner.pm" or die $!;
    local $/;
    <$fh>;
};
like($source, qr/mb226-B1/, 'ScriptRunner source contains mb226 marker');
unlike($source, qr/`[^`]+`|\bqx\s*(?:\/|\(|\{)|\bsystem\s*(?:\(|\s)/, 'mb226 does not introduce shell-oriented execution');

done_testing();
