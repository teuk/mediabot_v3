#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use Test::More;
use JSON::PP qw(decode_json);

use lib '.';
use Mediabot::ScriptRunner;

{
    package Local::MB287::ExplodingPayload;
    use overload
        '""' => sub { die 'payload object stringified unexpectedly' },
        fallback => 1;
    sub new { bless {}, shift }
}

my $runner = Mediabot::ScriptRunner->new(script_dir => 'plugins/scripts');

my $payload = $runner->build_event_payload('public_command', command => 'hello');
my $json = $runner->encode_event_payload($payload);
my $decoded = decode_json($json);

is(ref($decoded), 'HASH', 'normal payload still encodes as a JSON object');
is($decoded->{protocol}, 'mediabot-script-v1', 'normal payload keeps protocol');
is($decoded->{event}, 'public_command', 'normal payload keeps event');
is($decoded->{data}{command}, 'hello', 'normal payload keeps data');

for my $case (
    [ 'undef payload', undef ],
    [ 'scalar payload', 'not an object' ],
    [ 'ARRAY ref payload', [ protocol => 'mediabot-script-v1' ] ],
    [ 'overloaded payload object', Local::MB287::ExplodingPayload->new ],
) {
    my ($label, $bad_payload) = @$case;
    my $encoded;
    my @warnings;
    my $ok = eval {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        $encoded = $runner->encode_event_payload($bad_payload);
        1;
    };

    ok($ok, "$label is handled without dying");
    is_deeply(\@warnings, [], "$label emits no warning or overload stringification");

    my $bad_decoded = decode_json($encoded);
    is(ref($bad_decoded), 'HASH', "$label encodes as a JSON object fallback");
    is_deeply($bad_decoded, {}, "$label becomes an empty JSON object fallback");
}

my $plan = $runner->build_execution_plan('hello.py', $payload);
ok($plan->{ok}, 'build_execution_plan still accepts normal HASH payload after encoder guard');
is(ref(decode_json($plan->{stdin})), 'HASH', 'execution-plan stdin remains a JSON object');

my $bad_plan = $runner->build_execution_plan('hello.py', [ protocol => 'mediabot-script-v1' ]);
ok(!$bad_plan->{ok}, 'build_execution_plan still rejects ARRAY payloads explicitly');
is($bad_plan->{error}, 'payload must be object', 'explicit execution-plan error is preserved');
ok(!exists $bad_plan->{stdin}, 'rejected execution plan still has no stdin');

my $source = do {
    local $/;
    open my $fh, '<', 'Mediabot/ScriptRunner.pm' or die "open ScriptRunner.pm: $!";
    <$fh>;
};

like($source, qr/mb287-B1/, 'ScriptRunner source contains mb287 encoder object marker');
unlike($source, qr/`[^`]+`|\bqx\s*(?:\/|\(|\{)|\bsystem\s*(?:\(|\s)/, 'mb287 encoder guard does not introduce shell execution');

done_testing();
