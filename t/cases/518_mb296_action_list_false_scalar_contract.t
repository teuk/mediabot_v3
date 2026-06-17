#!/usr/bin/env perl
use strict;
use warnings;
use lib '.';
use Test::More;

use Mediabot::ScriptActionRunner;

my $runner = Mediabot::ScriptActionRunner->new();
my $ctx = { channel => '#teuk', nick => 'TeuK' };

sub first_error {
    my ($plan) = @_;
    my $err = $plan->{errors}[0];
    return ref($err) eq 'HASH' ? ($err->{error} // '') : ($err // '');
}

for my $case (
    [ 0,   'numeric zero' ],
    [ '0', 'string zero' ],
    [ '',  'empty string' ],
) {
    my ($value, $label) = @$case;

    my $plan = $runner->plan_actions($value, $ctx);
    ok(!$plan->{ok}, "$label is rejected by plan_actions");
    is_deeply($plan->{planned}, [], "$label plans no actions");
    like(first_error($plan), qr/actions must be an array/, "$label reports array contract");

    my $dry = $runner->apply_actions_dry({
        ok       => 1,
        response => {
            ok      => 1,
            actions => $value,
        },
    }, $ctx);

    ok(!$dry->{ok}, "$label is rejected through apply_actions_dry");
    is_deeply($dry->{planned}, [], "$label dry-run plans no actions");
    like(first_error($dry), qr/actions must be an array/, "$label dry-run reports array contract");

    my $apply = $runner->apply_actions({
        ok       => 1,
        response => {
            ok      => 1,
            actions => $value,
        },
    }, $ctx, apply => 1, allow_irc => 1);

    ok(!$apply->{ok}, "$label is rejected before apply");
    is_deeply($apply->{applied}, [], "$label applies no actions");
    ok(!$apply->{applied_ok}, "$label keeps applied_ok false");
}

my $missing = $runner->plan_actions(undef, $ctx);
ok($missing->{ok}, 'missing actions remains compatible with empty action list');
is_deeply($missing->{planned}, [], 'missing actions plans nothing');
is_deeply($missing->{errors}, [], 'missing actions reports no error');

my $empty_array = $runner->plan_actions([], $ctx);
ok($empty_array->{ok}, 'explicit empty action array remains valid');
is_deeply($empty_array->{planned}, [], 'explicit empty action array plans nothing');

my $source = do {
    local $/;
    open my $fh, '<', 'Mediabot/ScriptActionRunner.pm' or die $!;
    <$fh>;
};
like($source, qr/MB296: an omitted actions field remains compatible/,
    'source documents missing-versus-false-scalar distinction');
unlike($source, qr/\$actions\s*\|\|=\s*\[\]/,
    'plan_actions no longer collapses false scalar actions with ||=');
unlike($source, qr/plan_actions\(\$actions\s*\|\|\s*\[\]/,
    'apply_actions_dry no longer collapses false scalar actions');

done_testing();
