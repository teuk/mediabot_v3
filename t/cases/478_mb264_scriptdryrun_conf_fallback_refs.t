#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use Test::More tests => 16;
use lib '.';

BEGIN { use_ok('Mediabot::Plugin::ScriptDryRun') }

{
    package MB264Conf;
    sub new { my ($class, %data) = @_; return bless \%data, $class; }
    sub get { my ($self, $key) = @_; return $self->{$key}; }
}

{
    package MB264Bot;
    sub new { my ($class, $conf) = @_; return bless { conf => $conf }, $class; }
    sub events { return undef; }
}

my $P = 'Mediabot::Plugin::ScriptDryRun';

{
    my $bot = MB264Bot->new(MB264Conf->new(
        'plugins.ScriptDryRun.SCRIPT' => [],
        'SCRIPT_DRYRUN_SCRIPT'        => ' examples/hello_perl.pl ',
    ));
    my $plugin = $P->register($bot);

    is($plugin->script_path, 'examples/hello_perl.pl',
        'empty ARRAY in first SCRIPT key does not mask fallback SCRIPT key');
    ok($plugin->command_allowed('anything'),
        'fallback SCRIPT key still enables observation');
}

{
    my $bot = MB264Bot->new(MB264Conf->new(
        'plugins.ScriptDryRun.SCRIPT' => { bad => 'examples/bad.pl' },
        'SCRIPT_DRYRUN_PATH'          => ' examples/hello_python.py ',
    ));
    my $plugin = $P->register($bot);

    is($plugin->script_path, 'examples/hello_python.py',
        'HASH ref in first SCRIPT key does not mask fallback SCRIPT_DRYRUN_PATH');
    ok($plugin->command_allowed('anything'),
        'HASH ref is skipped rather than stringified as a configured script');
}

{
    my $bot = MB264Bot->new(MB264Conf->new(
        'plugins.ScriptDryRun.COMMANDS' => [],
        'SCRIPT_DRYRUN_COMMANDS'        => ' hello,pyhello ',
    ));
    my $plugin = $P->register($bot);

    ok($plugin->command_filter_enabled,
        'empty ARRAY in first COMMANDS key does not mask fallback COMMANDS key');
    ok($plugin->command_allowed('hello'),
        'fallback COMMANDS key allows hello');
    ok($plugin->_command_is_scoped('pyhello'),
        'fallback COMMANDS key scopes pyhello');
}

{
    my $bot = MB264Bot->new(MB264Conf->new(
        'plugins.ScriptDryRun.ROUTES' => { bad => 'hello=bad.pl' },
        'SCRIPT_DRYRUN_ROUTES'        => ' hello=examples/hello_perl.pl ',
    ));
    my $plugin = $P->register($bot);

    ok($plugin->command_routes_enabled,
        'HASH ref in first ROUTES key does not mask fallback ROUTES key');
    is($plugin->script_for_command('hello'), 'examples/hello_perl.pl',
        'fallback ROUTES key is parsed correctly');
    ok($plugin->_command_is_scoped('hello'),
        'fallback ROUTES key scopes hello');
}

{
    my $bot = MB264Bot->new(MB264Conf->new(
        'plugins.ScriptDryRun.ACTION_MODE' => [],
        'SCRIPT_DRYRUN_ACTION_MODE'        => ' apply ',
        'plugins.ScriptDryRun.ALLOW_IRC'   => [],
        'SCRIPT_DRYRUN_ALLOW_IRC'          => ' yes ',
        'plugins.ScriptDryRun.APPLY_REQUIRE_SCOPE' => [],
        'SCRIPT_DRYRUN_APPLY_REQUIRE_SCOPE'        => ' no ',
    ));
    my $plugin = $P->register($bot);

    is($plugin->action_mode, 'apply',
        'empty ARRAY in ACTION_MODE key does not mask fallback ACTION_MODE');
    ok($plugin->allow_irc,
        'empty ARRAY in ALLOW_IRC key does not mask fallback ALLOW_IRC');
    ok(!$plugin->apply_require_scope,
        'empty ARRAY in APPLY_REQUIRE_SCOPE key does not mask explicit fallback opt-out');
}

{
    my $src = do {
        open my $fh, '<', 'Mediabot/Plugin/ScriptDryRun.pm'
            or die "cannot open ScriptDryRun.pm: $!";
        local $/;
        <$fh>;
    };

    ok($src =~ /mb264-B1/,
        'ScriptDryRun source contains mb264 config fallback marker');
    ok($src !~ /system\s*\(|qx\//,
        'mb264 config fallback guard does not introduce shell execution');
}
