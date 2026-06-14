#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use Test::More tests => 22;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use lib '.';

# mb260-B4: standalone Test::More version of Claude mb225 regression.
# It also ensures A2/A3 are tested against the real module path:
# Mediabot/Plugin/ScriptDryRun.pm.

# A2: _command_is_scoped, ownership only when scope is explicit.
{
    require Mediabot::Plugin::ScriptDryRun;
    my $P = 'Mediabot::Plugin::ScriptDryRun';
    no strict 'refs';
    no warnings 'redefine';
    local *{"${P}::command_filter"} = sub { $_[0]->{command_filter} };
    local *{"${P}::command_routes"} = sub { $_[0]->{command_routes} };

    my $mk = sub { bless { command_filter => $_[0] || {}, command_routes => $_[1] || {} }, $P };
    my $bare   = $mk->({}, {});
    my $cmds   = $mk->({ hello => 1 }, {});
    my $routed = $mk->({}, { pyhello => 'y.pl' });

    ok(!$bare->_command_is_scoped('anything'), 'A2: bare SCRIPT owns no command');
    ok($cmds->_command_is_scoped('hello'), 'A2: command listed in COMMANDS is scoped');
    ok(!$cmds->_command_is_scoped('other'), 'A2: command outside COMMANDS is not scoped');
    ok($routed->_command_is_scoped('pyhello'), 'A2: routed command is scoped');
    ok(!$routed->_command_is_scoped('other'), 'A2: unrelated command is not scoped');
}

# A1: max_errors configurable.
{
    require Mediabot::ScriptActionRunner;

    my $default = Mediabot::ScriptActionRunner->new();
    is($default->max_errors, 20, 'A1: default max_errors is 20');

    my $custom = Mediabot::ScriptActionRunner->new(max_errors => 5);
    is($custom->max_errors, 5, 'A1: max_errors can be configured to 5');

    my $lo = Mediabot::ScriptActionRunner->new(max_errors => 0);
    is($lo->max_errors, 1, 'A1: max_errors lower bound is 1');

    my $hi = Mediabot::ScriptActionRunner->new(max_errors => 9999);
    is($hi->max_errors, 100, 'A1: max_errors upper bound is 100');

    my $r = $custom->apply_actions_dry({
        ok       => 0,
        response => { ok => 0, errors => [ map { "err$_" } 1..20 ] },
    }, { channel => '#t' });
    is(scalar(@{ $r->{errors} || [] }), 5, 'A1: propagated errors are capped by max_errors');
}

# A3: _truthy_with_default.
{
    require Mediabot::Plugin::ScriptDryRun;
    my $f = \&Mediabot::Plugin::ScriptDryRun::_truthy_with_default;

    is($f->(undef, 1), 1, 'A3: unset value uses default 1');
    is($f->(undef, 0), 0, 'A3: unset value uses default 0');
    is($f->('no', 1),  0, q{A3: explicit 'no' overrides default});
    is($f->('yes', 0), 1, q{A3: explicit 'yes' overrides default});
    is($f->('', 1),    1, 'A3: empty string uses default');
    is($f->([ 'no' ], 1), 0, q{A3: ARRAY ref ['no'] is handled without Perl ref stringification});
}

# A4: containment realpath when the script file does not exist yet.
{
    require Mediabot::ScriptRunner;
    my $root = tempdir(CLEANUP => 1);
    make_path("$root/scripts/examples");
    make_path("$root/outside");
    my $sym_ok = eval { symlink("$root/outside", "$root/scripts/evil"); 1; };

    my $sr = Mediabot::ScriptRunner->new(script_dir => "$root/scripts", timeout => 2);

    my ($ok_sub) = $sr->validate_script_path('examples/new.pl');
    is(($ok_sub // 0), 1, 'A4: missing script under internal directory is allowed');

    my ($ok_top) = $sr->validate_script_path('brandnew.pl');
    is(($ok_top // 0), 1, 'A4: missing top-level script is allowed');

    if ($sym_ok && -l "$root/scripts/evil") {
        my ($ok_evil, $err_evil) = $sr->validate_script_path('evil/x.pl');
        ok(($ok_evil // 0) == 0 && ($err_evil // '') =~ /escapes/,
            'A4: symlinked intermediate directory escaping script_dir is rejected even when target file is missing');
    }
    else {
        pass('A4: symlink unavailable, escape case skipped');
    }
}

# A5: lang + resolved_path in run_script result.
{
    require Mediabot::ScriptRunner;
    my $sr = Mediabot::ScriptRunner->new(timeout => 3);
    my $r = $sr->run_script('examples/hello_perl.pl', 'public_command',
        command => 'x', nick => 'teuk');

    ok(ref($r) eq 'HASH' && ($r->{ok} // 0) == 1, 'A5: hello_perl.pl executes successfully');
    is($r->{lang}, 'perl', 'A5: result exposes lang=perl');
    like($r->{resolved_path} // '', qr/hello_perl\.pl\z/, 'A5: result exposes resolved_path');
}
