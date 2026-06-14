#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use Test::More tests => 11;
use lib '.';
use Mediabot::ScriptActionRunner;

# mb260-B3: standalone Test::More version of Claude mb224 regression.
# The previous file used the old custom-harness `return sub { ... }` shape even
# though the validation command was `perl -I. t/cases/472_...t`, which fails with
# "Can't return outside a subroutine".

my $ar  = Mediabot::ScriptActionRunner->new(max_actions => 20);
my $ctx = { channel => '#teuk' };

sub planned_errors {
    my ($result) = @_;
    my $plan = $ar->apply_actions_dry($result, $ctx);
    return [ map { $_->{error} } @{ $plan->{errors} || [] } ];
}

{
    my $e = planned_errors({
        ok       => 0,
        response => {
            ok     => 0,
            errors => [ { bad => 1 }, [ 'nested' ], 'action layer scalar error' ],
        },
    });
    is_deeply($e, [ 'action layer scalar error' ],
        'mb224 t1: scalar response.errors diagnostics are propagated without generic noise');
}

{
    my $e = planned_errors({
        ok       => 0,
        response => { ok => 0, errors => [ { bad => 1 }, [ 'nested' ] ] },
    });
    is_deeply($e, [ 'script result is not ok' ],
        'mb224 t2: nested-only errors fall back to one top-level generic diagnostic');
}

{
    my $e = planned_errors({
        ok       => 0,
        response => { ok => 1, actions => [ { type => 'reply', text => 'x' } ] },
    });
    is(scalar(@$e), 1, 'mb224 t3a: top ok=0 without details gives one error');
    like($e->[0], qr/not ok/, 'mb224 t3b: top ok=0 reports not-ok fallback');
}

{
    my $e = planned_errors({
        ok       => 1,
        response => { ok => 0, actions => [ { type => 'reply', text => 'x' } ] },
    });
    is_deeply($e, [ 'script response is not ok' ],
        'mb224 t4: response ok=0 without details gives response-level fallback');
}

{
    my $e = planned_errors({
        ok       => [1],
        response => { ok => 1, actions => [ { type => 'reply', text => 'x' } ] },
    });
    like($e->[0] // '', qr/top-level ok must be a JSON boolean/,
        'mb224 t5: top-level invalid ok reports scalar contract before generic fallback');

    my $e2 = planned_errors({
        ok       => 1,
        response => { ok => { bad => 1 }, actions => [ { type => 'reply', text => 'x' } ] },
    });
    like($e2->[0] // '', qr/response ok must be a JSON boolean/,
        'mb224 t6: response invalid ok reports scalar contract');
}

{
    my $e = planned_errors({
        response => {
            ok      => 0,
            errors  => [ 'script response failed' ],
            actions => [ { type => 'reply', text => 'x' } ],
        },
    });
    my $joined = join(' ', @$e);
    like($joined, qr/script response failed/,
        'mb224 t7: scalar response.errors diagnostic is preserved');
    ok(!grep({ $_ =~ /HASH\(|ARRAY\(/ } @$e),
        'mb224 t8: no stringified Perl references appear in errors');
}

{
    my $e = planned_errors({ ok => 0, timeout => 1, response => { ok => 0 } });
    ok((grep { $_ eq 'script timed out' } @$e) > 0,
        'mb224 t9: timeout diagnostic is present');
    ok(!grep({ $_ eq 'script result is not ok' } @$e),
        'mb224 t10: specific timeout diagnostic suppresses generic not-ok fallback');
}
