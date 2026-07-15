#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../..";

use Mediabot::ScriptActionRunner;

my $runner = Mediabot::ScriptActionRunner->new(max_text_length => 400);

sub script_result_for {
    my (@actions) = @_;
    return {
        ok       => 1,
        timeout  => 0,
        response => {
            ok      => 1,
            errors  => [],
            actions => \@actions,
        },
    };
}

my ($ok_valid, $err_valid, $planned_valid) = $runner->validate_action(
    { type => 'timer', name => 'demo_timer-1.ok', delay => 15 },
    { channel => '#teuk' },
);

ok($ok_valid, 'safe timer name remains valid');
is($planned_valid->{name}, 'demo_timer-1.ok', 'safe timer name is preserved');
is($planned_valid->{delay}, 15, 'safe timer delay is preserved');

for my $case (
    [ "bad\nname",     qr/forbidden control/,    'timer name with newline is rejected' ],
    [ "bad\rname",     qr/forbidden control/,    'timer name with carriage return is rejected' ],
    [ "bad\0name",     qr/forbidden control/,    'timer name with NUL is rejected' ],
    [ 'two words',      qr/whitespace/,           'timer name with whitespace is rejected' ],
    [ 'semi;colon',     qr/unsupported/,          'timer name with semicolon is rejected' ],
    [ 'colon:name',     qr/unsupported/,          'timer name with colon is rejected' ],
    [ ('x' x 65),       qr/too long/,             'timer name longer than 64 chars is rejected' ],
) {
    my ($name, $expected, $label) = @$case;
    my ($ok, $err) = $runner->validate_action(
        { type => 'timer', name => $name, delay => 10 },
        { channel => '#teuk' },
    );
    ok(!$ok, $label);
    like(($err || ''), $expected, "$label reports expected reason");
}

my $mixed = $runner->apply_actions(
    script_result_for(
        { type => 'timer', name => "bad\nname", delay => 10 },
        { type => 'reply', target => '#teuk', text => 'must not apply' },
    ),
    { channel => '#teuk' },
    apply     => 1,
    allow_irc => 1,
);

ok(!$mixed->{ok}, 'mixed plan is invalid when timer name is unsafe');
is(scalar @{ $mixed->{planned} || [] }, 1, 'only the safe action is planned before all-or-nothing apply');
ok(!$mixed->{applied_ok}, 'invalid mixed plan is not applied');
like(($mixed->{errors}[0]{error} || ''), qr/forbidden control/, 'invalid timer error is exposed');

my $valid_timer = $runner->apply_actions(
    script_result_for({ type => 'timer', name => 'demo_timer', delay => 10 }),
    { channel => '#teuk' },
    apply     => 1,
    allow_irc => 1,
);

# mb525-B1: les timers sont appliques via un ordonnanceur injecte; sans
# schedule_timer, l'application reste fail-closed avec une erreur explicite.
ok($valid_timer->{ok}, 'valid timer still plans successfully');
ok(!$valid_timer->{applied_ok}, 'valid timer is not applied without an injected scheduler');
like(($valid_timer->{apply_errors}[0]{error} || ''), qr/require a scheduler/, 'valid timer reports scheduler-required at apply time');

open my $fh, '<', 'Mediabot/ScriptActionRunner.pm' or die "cannot read ScriptActionRunner.pm: $!";
my $src = do { local $/; <$fh> };
close $fh;

like($src, qr/mb235-B1: timer action names are future runtime identifiers/, 'ScriptActionRunner source contains mb235 timer guard marker');
unlike($src, qr/dbh->|prepare\(|INSERT|UPDATE|DELETE|system\s*\(|qx\//, 'mb235 timer guard does not introduce DB writes or shell execution');

done_testing();
