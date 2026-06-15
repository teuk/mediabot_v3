#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin qw($Bin);
use lib "$Bin/../..";

use JSON::PP qw(decode_json);
use Mediabot::ScriptRunner;

{
    package Local::MB285::StringyPayload;
    use overload '""' => sub { $_[0]->{value} }, fallback => 1;
    sub new { bless { value => $_[1] }, $_[0] }
}

my $tmp = tempdir(CLEANUP => 1);
my $script_dir = "$tmp/scripts";
make_path($script_dir);

my $runner = Mediabot::ScriptRunner->new(script_dir => $script_dir);
my $payload = $runner->build_event_payload('public_command', command => 'hello', args => [ 'world' ]);

my $good = $runner->build_execution_plan('hello.py', $payload);
ok($good->{ok}, 'normal HASH payload still builds an execution plan');
is($good->{language}, 'python', 'normal HASH payload keeps language detection');

my $decoded = decode_json($good->{stdin});
is(ref($decoded), 'HASH', 'execution plan stdin remains a JSON object envelope');
is($decoded->{protocol}, 'mediabot-script-v1', 'JSON object envelope keeps protocol');
is($decoded->{event}, 'public_command', 'JSON object envelope keeps event');
is($decoded->{data}{command}, 'hello', 'JSON object envelope keeps command data');

my $undef_payload = $runner->build_execution_plan('hello.py', undef);
ok($undef_payload->{ok}, 'undef payload keeps the historical empty-object fallback');
is(ref(decode_json($undef_payload->{stdin})), 'HASH', 'undef payload fallback encodes as a JSON object');

for my $case (
    [ 'plain scalar payload', 'not an object' ],
    [ 'ARRAY ref payload', [ protocol => 'mediabot-script-v1' ] ],
    [ 'overloaded payload object', Local::MB285::StringyPayload->new('{"protocol":"mediabot-script-v1"}') ],
) {
    my ($label, $bad_payload) = @$case;
    my $plan = $runner->build_execution_plan('hello.py', $bad_payload);

    ok(!$plan->{ok}, "$label is rejected");
    is($plan->{error}, 'payload must be object', "$label returns explicit object-contract error");
    is_deeply($plan->{command}, [], "$label produces no argv command");
    ok(!exists $plan->{stdin}, "$label is rejected before JSON stdin is prepared");
}

my $dry = $runner->run_dry('hello.py', 'public_command', command => 'hello');
ok($dry->{ok}, 'run_dry still builds a normal object payload from event/data');
is(ref(decode_json($dry->{stdin})), 'HASH', 'run_dry stdin is still a JSON object envelope');

my @warnings;
{
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    $runner->build_execution_plan('hello.py', [ protocol => 'mediabot-script-v1' ]);
    $runner->build_execution_plan('hello.py', Local::MB285::StringyPayload->new('{"event":"public_command"}'));
}
is_deeply(\@warnings, [], 'payload object rejection is quiet and does not stringify refs');

my $source = do {
    local $/;
    open my $fh, '<', "$Bin/../../Mediabot/ScriptRunner.pm" or die "open ScriptRunner.pm: $!";
    <$fh>;
};

like($source, qr/mb285-B1/, 'ScriptRunner source contains mb285 payload object marker');
unlike($source, qr/`[^`]+`|\bqx\s*(?:\/|\(|\{)|\bsystem\s*(?:\(|\s)/, 'mb285 payload guard does not introduce shell execution');

done_testing();
