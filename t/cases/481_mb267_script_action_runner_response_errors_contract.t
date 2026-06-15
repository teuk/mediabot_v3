#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/../..";
use Test::More;

use Mediabot::ScriptActionRunner;

my $runner = Mediabot::ScriptActionRunner->new(max_errors => 5);
my $ctx = { channel => '#teuk' };

sub plan_for {
    my ($result) = @_;
    return $runner->apply_actions_dry($result, $ctx);
}

sub joined_errors {
    my ($plan) = @_;
    return join ' ', map {
        ref($_) eq 'HASH' ? ($_->{error} // '') : ''
    } @{ $plan->{errors} || [] };
}

my $legacy_ok = plan_for({
    response => {
        actions => [ { type => 'log', text => 'legacy action still works' } ],
    },
});
ok($legacy_ok->{ok}, 'legacy direct response without ok/errors still succeeds');
is(scalar @{ $legacy_ok->{planned} || [] }, 1, 'legacy direct response still plans one action');

my $empty_errors = plan_for({
    response => {
        errors  => [],
        actions => [ { type => 'log', text => 'empty errors still works' } ],
    },
});
ok($empty_errors->{ok}, 'empty response.errors does not fail by itself');
is(scalar @{ $empty_errors->{planned} || [] }, 1, 'empty response.errors still allows valid actions');

my $scalar_errors = plan_for({
    response => {
        errors  => [ 'script said no' ],
        actions => [ { type => 'log', text => 'must not be planned' } ],
    },
});
ok(!$scalar_errors->{ok}, 'non-empty response.errors without response.ok closes action layer');
is(scalar @{ $scalar_errors->{planned} || [] }, 0, 'response.errors failure plans no actions');
like(joined_errors($scalar_errors), qr/script said no/, 'scalar response.errors diagnostic is preserved');
unlike(joined_errors($scalar_errors), qr/script result is not ok/, 'specific response.errors diagnostic is not hidden by generic fallback');

my $nested_errors = plan_for({
    response => {
        errors  => [ { bad => 1 }, [ 'nested' ] ],
        actions => [ { type => 'log', text => 'must not be planned either' } ],
    },
});
ok(!$nested_errors->{ok}, 'nested-only response.errors still closes action layer');
is(scalar @{ $nested_errors->{planned} || [] }, 0, 'nested-only response.errors plans no actions');
like(joined_errors($nested_errors), qr/script result is not ok/, 'nested-only response.errors falls back cleanly');
unlike(joined_errors($nested_errors), qr/HASH|ARRAY/, 'nested-only response.errors are never stringified');

my $malformed_errors = plan_for({
    response => {
        errors  => 'not an array',
        actions => [ { type => 'log', text => 'must not pass malformed errors' } ],
    },
});
ok(!$malformed_errors->{ok}, 'scalar response.errors field is malformed and closes action layer');
is(scalar @{ $malformed_errors->{planned} || [] }, 0, 'malformed response.errors plans no actions');
like(joined_errors($malformed_errors), qr/response errors must be an array/, 'malformed response.errors reports contract error');

my $source = do {
    open my $fh, '<', 'Mediabot/ScriptActionRunner.pm' or die $!;
    local $/;
    <$fh>;
};
like($source, qr/mb267-B1/, 'ScriptActionRunner source contains mb267 diagnostic marker');
like($source, qr/mb267-B2/, 'ScriptActionRunner source contains mb267 failure marker');
unlike($source, qr/system\s*\(/, 'mb267 response.errors guard does not introduce system()');

done_testing();
