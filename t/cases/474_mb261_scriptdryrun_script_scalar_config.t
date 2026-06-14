#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use Test::More tests => 15;
use lib '.';

require Mediabot::Plugin::ScriptDryRun;

{
    package MB261Conf;
    sub new { my ($class, %data) = @_; return bless \%data, $class; }
    sub get { my ($self, $key) = @_; return $self->{$key}; }
}

{
    package MB261Bot;
    sub new { my ($class, $conf) = @_; return bless { conf => $conf }, $class; }
    sub events { return undef; }
}

my $P = 'Mediabot::Plugin::ScriptDryRun';

{
    my $bot = MB261Bot->new(MB261Conf->new(
        'plugins.ScriptDryRun.SCRIPT' => [ ' examples/hello_perl.pl ' ],
    ));
    my $plugin = $P->register($bot);

    is(ref($plugin->script_path) || '', '', 'SCRIPT ARRAY config is normalized to a scalar');
    is($plugin->script_path, 'examples/hello_perl.pl', 'SCRIPT ARRAY config keeps first meaningful script path');
    ok($plugin->command_allowed('anything'), 'scalar SCRIPT fallback still allows observation for any command');
    is($plugin->script_for_command('anything'), 'examples/hello_perl.pl', 'SCRIPT fallback returns a scalar script path');
    ok(!$plugin->_command_is_scoped('anything'), 'bare SCRIPT fallback still does not own unscoped command');
}

{
    my $bot = MB261Bot->new(MB261Conf->new(
        'plugins.ScriptDryRun.SCRIPT' => [ '', [ ' examples/hello_python.py ' ] ],
    ));
    my $plugin = $P->register($bot);

    is($plugin->script_path, 'examples/hello_python.py', 'nested SCRIPT ARRAY config is flattened safely');
    is($plugin->script_for_command('x'), 'examples/hello_python.py', 'nested SCRIPT ARRAY fallback remains scalar');
}

{
    my $bot = MB261Bot->new(MB261Conf->new(
        'plugins.ScriptDryRun.SCRIPT' => { bad => 'examples/hello_perl.pl' },
    ));
    my $plugin = $P->register($bot);

    ok(!defined $plugin->script_path, 'SCRIPT HASH config is ignored instead of stringified');
    ok(!$plugin->command_allowed('anything'), 'HASH SCRIPT config does not enable fallback observation');
    ok(!defined $plugin->script_for_command('anything'), 'HASH SCRIPT config does not return HASH(...) as a script path');
}

{
    my $bot = MB261Bot->new(MB261Conf->new(
        'plugins.ScriptDryRun.COMMANDS' => { bad => 'hello' },
        'plugins.ScriptDryRun.ALLOW_IRC' => { bad => 'yes' },
        'plugins.ScriptDryRun.APPLY_REQUIRE_SCOPE' => { bad => 'no' },
    ));
    my $plugin = $P->register($bot);

    ok(!$plugin->command_filter_enabled, 'COMMANDS HASH config is ignored instead of stringified');
    ok(!$plugin->allow_irc, 'ALLOW_IRC HASH config is ignored instead of stringified');
    ok($plugin->apply_require_scope, 'APPLY_REQUIRE_SCOPE HASH config falls back to safe default');
}

{
    my $src = do {
        open my $fh, '<', 'Mediabot/Plugin/ScriptDryRun.pm'
            or die "cannot open ScriptDryRun.pm: $!";
        local $/;
        <$fh>;
    };

    ok($src =~ /mb261-B1/ && $src =~ /mb261-B2/ && $src =~ /mb261-B3/,
        'ScriptDryRun source contains mb261 scalar config markers');
    ok($src !~ /system\s*\(|qx\//,
        'mb261 config guard does not introduce shell execution');
}
