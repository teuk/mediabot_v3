#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use Test::More;
use JSON::PP qw(decode_json);

use lib '.';
use Mediabot::ScriptRunner;

{
    package Local::MB289::ExplodingValue;
    use overload
        '""' => sub { die 'event data object stringified unexpectedly' },
        fallback => 1;
    sub new { bless {}, shift }
}

my $runner = Mediabot::ScriptRunner->new(script_dir => 'plugins/scripts');

my $payload = $runner->build_event_payload(
    'public_command',
    channel => '#teuk',
    target  => '#teuk',
    nick    => 'Te[u]K',
    command => 'pyhello',
    args    => [ 'one', 2, undef, [ 'bad' ], { bad => 1 }, Local::MB289::ExplodingValue->new, 'three' ],
    hashref => { must => 'not leak' },
    object  => Local::MB289::ExplodingValue->new,
);

is($payload->{data}{channel}, '#teuk', 'scalar channel is preserved');
is($payload->{data}{command}, 'pyhello', 'scalar command is preserved');
is_deeply($payload->{data}{args}, [ 'one', '2', 'three' ], 'args ARRAY keeps only scalar values');
ok(exists $payload->{data}{hashref}, 'invalid HASH value keeps field presence for compatibility');
is($payload->{data}{hashref}, undef, 'HASH value becomes JSON null fallback');
is($payload->{data}{object}, undef, 'object value becomes JSON null fallback without overload');

my $json = $runner->encode_event_payload($payload);
my $decoded = decode_json($json);
is(ref($decoded), 'HASH', 'encoded payload remains a JSON object');
is(ref($decoded->{data}), 'HASH', 'encoded data remains a JSON object');
is_deeply($decoded->{data}{args}, [ 'one', '2', 'three' ], 'encoded args contains only scalar values');
ok(!defined $decoded->{data}{hashref}, 'encoded HASH fallback is JSON null');
ok(!defined $decoded->{data}{object}, 'encoded object fallback is JSON null');

my @warnings;
my $ok = eval {
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    my $bad = $runner->build_event_payload(
        'public_command',
        command => Local::MB289::ExplodingValue->new,
        args    => [ Local::MB289::ExplodingValue->new ],
    );
    $runner->encode_event_payload($bad);
    1;
};

ok($ok, 'malformed event data is handled without dying');
is_deeply(\@warnings, [], 'malformed event data emits no warning or overload stringification');

my $dry = $runner->run_dry(
    'hello.py',
    'public_command',
    command => 'hello',
    args    => [ 'ok', { bad => 1 }, 'still-ok' ],
);
ok($dry->{ok}, 'run_dry still builds a valid execution plan');
my $stdin = decode_json($dry->{stdin});
is_deeply($stdin->{data}{args}, [ 'ok', 'still-ok' ], 'run_dry stdin data is sanitized before JSON');

my $source = do {
    local $/;
    open my $fh, '<', 'Mediabot/ScriptRunner.pm' or die "open ScriptRunner.pm: $!";
    <$fh>;
};

like($source, qr/mb289-B1/, 'ScriptRunner source contains mb289 event data marker');
unlike($source, qr/`[^`]+`|\bqx\s*(?:\/|\(|\{)|\bsystem\s*(?:\(|\s)/, 'mb289 event-data guard does not introduce shell execution');

done_testing();
