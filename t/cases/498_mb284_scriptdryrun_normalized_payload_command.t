#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use Test::More tests => 16;
use lib '.';

BEGIN { use_ok('Mediabot::Plugin::ScriptDryRun') }

{
    package MB284Conf;
    sub new { my ($class, %data) = @_; return bless \%data, $class; }
    sub get { my ($self, $key) = @_; return $self->{$key}; }
}

{
    package MB284Bot;
    sub new { my ($class, $conf) = @_; return bless { conf => $conf, ran => [] }, $class; }
    sub events { return undef; }
    sub run_script_actions_dry {
        my ($self, $script, $event, %data) = @_;
        push @{ $self->{ran} }, { script => $script, event => $event, data => \%data };
        return {
            ok            => 1,
            script_result => { ok => 1, response => { ok => 1, actions => [] } },
            action_plan   => { ok => 1, dry_run => 1, planned => [], errors => [] },
        };
    }
}

my $bot = MB284Bot->new(MB284Conf->new(
    'plugins.ScriptDryRun.SCRIPT'   => 'examples/hello_perl.pl',
    'plugins.ScriptDryRun.COMMANDS' => 'hello',
    'plugins.ScriptDryRun.ROUTES'   => 'pyhello=examples/hello_python.py',
));

my $plugin = Mediabot::Plugin::ScriptDryRun->register($bot);

ok($plugin->command_allowed('  !PyHello  '), 'raw prefixed mixed-case routed command is allowed by normalization');
ok($plugin->command_allowed(' .HELLO '), 'raw prefixed mixed-case allow-list command is allowed by normalization');
ok(!$plugin->command_allowed('hello world'), 'malformed command with internal whitespace still rejected');

my %route_ctx = (
    channel => '#teuk',
    target  => '#teuk',
    nick    => 'Te[u]K',
    command => '  !PyHello  ',
    args    => [ 'one', 'two' ],
);

my $route_result = $plugin->observe_public_command(\%route_ctx);
ok(ref($route_result) eq 'HASH' && $route_result->{ok}, 'normalized routed command is observed successfully');
ok($route_ctx{scriptdryrun_handled}, 'normalized routed command is marked handled because it is scoped by ROUTES');
is(scalar @{ $bot->{ran} }, 1, 'normalized routed command runs exactly one external script');
is($bot->{ran}[0]{script}, 'examples/hello_python.py', 'normalized routed command selects the configured route script');
is($bot->{ran}[0]{data}{command}, 'pyhello', 'external script payload receives canonical routed command token');

my %filter_ctx = (
    channel => '#teuk',
    target  => '#teuk',
    nick    => 'Te[u]K',
    command => ' .HELLO ',
    args    => [],
);

my $filter_result = $plugin->observe_public_command(\%filter_ctx);
ok(ref($filter_result) eq 'HASH' && $filter_result->{ok}, 'normalized allow-list command is observed successfully');
ok($filter_ctx{scriptdryrun_handled}, 'normalized allow-list command is marked handled because it is scoped by COMMANDS');
is(scalar @{ $bot->{ran} }, 2, 'normalized allow-list command runs exactly one more external script');
is($bot->{ran}[1]{script}, 'examples/hello_perl.pl', 'normalized allow-list command uses fallback SCRIPT when no route exists');
is($bot->{ran}[1]{data}{command}, 'hello', 'external script payload receives canonical allow-list command token');

my %bad_ctx = (
    channel => '#teuk',
    target  => '#teuk',
    nick    => 'Te[u]K',
    command => 'hello world',
    args    => [],
);

my $bad_result = $plugin->observe_public_command(\%bad_ctx);
ok(!defined $bad_result, 'malformed raw command is still skipped after observer canonicalization');
is(scalar @{ $bot->{ran} }, 2, 'malformed raw command does not reach the external script runner');
