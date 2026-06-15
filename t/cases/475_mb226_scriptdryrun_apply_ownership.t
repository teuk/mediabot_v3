#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use Test::More tests => 9;
use lib '.';

BEGIN { use_ok('Mediabot::Plugin::ScriptDryRun') }

my $P = 'Mediabot::Plugin::ScriptDryRun';

no strict 'refs';
no warnings 'redefine';
local *{"${P}::command_filter"} = sub { $_[0]->{command_filter} || {} };
local *{"${P}::command_routes"} = sub { $_[0]->{command_routes} || {} };
local *{"${P}::action_mode"}    = sub { $_[0]->{action_mode} || 'dry-run' };
use strict 'refs';

my $mk = sub {
    my (%h) = @_;
    return bless {
        command_filter => $h{filter} || {},
        command_routes => $h{routes} || {},
        action_mode    => $h{mode}   || 'dry-run',
    }, $P;
};

# Reproduce the ownership formula used by observe_public_command (mb226-B1).
# mb262 keeps this test directly executable with `perl -I. ...`.
my $owns = sub {
    my ($plugin, $command) = @_;
    return ($plugin->_command_is_scoped($command)
        || $plugin->action_mode eq 'apply') ? 1 : 0;
};

{
    my $routed = $mk->(routes => { foo => 'r.pl' }, mode => 'dry-run');
    ok($owns->($routed, 'foo') == 1,
        'mb226 dry-run: routed command is owned');
    ok($owns->($routed, 'bar') == 0,
        'mb226 dry-run: non-routed fallback command is not owned');

    my $cmds = $mk->(filter => { hello => 1 }, mode => 'dry-run');
    ok($owns->($cmds, 'hello') == 1,
        'mb226 dry-run: command listed in COMMANDS is owned');
    ok($owns->($cmds, 'other') == 0,
        'mb226 dry-run: command outside COMMANDS is not owned');

    my $bare = $mk->(mode => 'dry-run');
    ok($owns->($bare, 'anything') == 0,
        'mb226 dry-run: bare SCRIPT owns nothing');
}

{
    my $routed = $mk->(routes => { foo => 'r.pl' }, mode => 'apply');
    ok($owns->($routed, 'foo') == 1,
        'mb226 apply: routed command is owned');
    ok($owns->($routed, 'bar') == 1,
        'mb226 apply: running fallback path is owned when execution is allowed');

    my $bare = $mk->(mode => 'apply');
    ok($owns->($bare, 'anything') == 1,
        'mb226 apply: bare SCRIPT owns what it applies when scope guard is explicitly disabled');
}
