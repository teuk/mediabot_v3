#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use lib '.';
use Test::More;

use Mediabot::ScriptActionRunner;

{
    package MB290::ExplosiveError;
    use overload '""' => sub { die 'MB290 top-level error was stringified' }, fallback => 0;
}

my $runner = Mediabot::ScriptActionRunner->new(max_errors => 5);
my $ctx = { channel => '#teuk' };

sub plan_for {
    my ($result) = @_;
    return $runner->apply_actions_dry($result, $ctx);
}

sub joined_errors {
    my ($plan) = @_;
    return join ' ', map {
        ref($_) eq 'HASH' ? ($_->{error} // '') : ($_ // '')
    } @{ $plan->{errors} || [] };
}

my $scalar_error_plan = plan_for({
    ok       => 1,
    error    => 'direct script runner failure',
    response => {
        ok      => 1,
        actions => [ { type => 'reply', text => 'must not pass' } ],
    },
});

ok(!$scalar_error_plan->{ok}, 'scalar top-level error closes the action layer');
is(scalar @{ $scalar_error_plan->{planned} || [] }, 0, 'scalar top-level error plans no actions');
like(joined_errors($scalar_error_plan), qr/direct script runner failure/, 'scalar top-level error diagnostic is preserved');

my $object_error = bless {}, 'MB290::ExplosiveError';
my $warnings = '';
my $object_error_plan;
my $died = eval {
    local $SIG{__WARN__} = sub { $warnings .= join '', @_ };
    $object_error_plan = plan_for({
        ok       => 1,
        error    => $object_error,
        response => {
            ok      => 1,
            actions => [ { type => 'reply', text => 'must not pass either' } ],
        },
    });
    1;
};

ok($died, 'object top-level error is handled without dying');
ok(!$object_error_plan->{ok}, 'object top-level error closes the action layer');
is(scalar @{ $object_error_plan->{planned} || [] }, 0, 'object top-level error plans no actions');
like(joined_errors($object_error_plan), qr/top-level error must be scalar/, 'object top-level error reports scalar contract');
unlike(joined_errors($object_error_plan), qr/HASH|ARRAY|MB290::ExplosiveError/, 'object top-level error is not stringified in diagnostics');
unlike($warnings, qr/stringified|overload|HASH|ARRAY|MB290::ExplosiveError/, 'object top-level error emits no stringification warning');

my $hash_error_plan = plan_for({
    ok       => 1,
    error    => { nested => 1 },
    response => {
        ok      => 1,
        actions => [ { type => 'log', text => 'must stay closed' } ],
    },
});

ok(!$hash_error_plan->{ok}, 'HASH top-level error closes the action layer');
like(joined_errors($hash_error_plan), qr/top-level error must be scalar/, 'HASH top-level error reports scalar contract');
unlike(joined_errors($hash_error_plan), qr/HASH\(/, 'HASH top-level error is not stringified');

my $source = do {
    open my $fh, '<', 'Mediabot/ScriptActionRunner.pm' or die $!;
    local $/;
    <$fh>;
};
like($source, qr/mb290-B1/, 'ScriptActionRunner source contains mb290 diagnostic marker');
like($source, qr/mb290-B2/, 'ScriptActionRunner source contains mb290 failure marker');
unlike($source, qr/`[^`]+`|\bqx\s*(?:\/|\(|\{)|\bsystem\s*(?:\(| )/, 'mb290 top-level error guard does not introduce shell execution');

done_testing();
