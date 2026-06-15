#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use Test::More tests => 12;
use lib '.';

BEGIN { use_ok('Mediabot::Plugin::ScriptDryRun') }

my $P = 'Mediabot::Plugin::ScriptDryRun';

my $mk = sub {
    my (%h) = @_;
    return bless {
        action_mode         => $h{mode} // 'dry-run',
        apply_require_scope => exists $h{require_scope} ? $h{require_scope} : 1,
        command_filter      => $h{filter} || {},
        command_routes      => $h{routes} || {},
        script_path         => $h{script},
    }, $P;
};

{
    my $dry = $mk->(mode => 'dry-run', script => 'fallback.pl');
    ok(!defined $dry->apply_scope_warning('anything'),
        'dry-run never triggers the apply scope guard');
}

{
    my $bare = $mk->(mode => 'apply', script => 'fallback.pl');
    like($bare->apply_scope_warning('anything') // '', qr/requires COMMANDS or ROUTES/,
        'apply + bare SCRIPT is rejected by default');
}

{
    my $optout = $mk->(mode => 'apply', require_scope => 0, script => 'fallback.pl');
    ok(!defined $optout->apply_scope_warning('anything'),
        'APPLY_REQUIRE_SCOPE=no preserves explicit opt-out');
}

{
    my $routes = $mk->(mode => 'apply', routes => { foo => 'foo.pl' }, script => 'fallback.pl');
    ok(!defined $routes->apply_scope_warning('foo'),
        'apply + ROUTES allows the routed command');
    like($routes->apply_scope_warning('bar') // '', qr/current command/,
        'apply + ROUTES plus fallback rejects an unrouted current command');
    ok($routes->command_allowed('bar'),
        'the fallback command is otherwise allowed by SCRIPT fallback');
}

{
    my $cmds = $mk->(mode => 'apply', filter => { hello => 1 }, script => 'fallback.pl');
    ok(!defined $cmds->apply_scope_warning('hello'),
        'apply + COMMANDS allows the listed command');
    like($cmds->apply_scope_warning('other') // '', qr/current command/,
        'apply + COMMANDS rejects a command outside the current scope');
    ok(!$cmds->command_allowed('other'),
        'COMMANDS still blocks the command before script execution');
}

{
    my $src = do {
        open my $fh, '<', 'Mediabot/Plugin/ScriptDryRun.pm'
            or die "cannot open ScriptDryRun.pm: $!";
        local $/;
        <$fh>;
    };

    ok($src =~ /mb262-B1/,
        'ScriptDryRun source contains mb262 current-command scope marker');
    ok($src !~ /system\s*\(|qx\//,
        'mb262 current-command scope guard does not introduce shell execution');
}
