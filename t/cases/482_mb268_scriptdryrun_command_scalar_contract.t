#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use Test::More tests => 14;
use lib '.';

BEGIN { use_ok('Mediabot::Plugin::ScriptDryRun') }

{
    package MB268Conf;
    sub new { my ($class, %data) = @_; return bless \%data, $class; }
    sub get { my ($self, $key) = @_; return $self->{$key}; }
}

{
    package MB268Bot;
    sub new { my ($class, $conf) = @_; return bless { conf => $conf, calls => 0 }, $class; }
    sub events { return undef; }
    sub run_script_actions_dry {
        my ($self) = @_;
        $self->{calls}++;
        return {
            ok            => 1,
            script_result => { ok => 1, response => { ok => 1, actions => [] } },
            action_plan   => { ok => 1, dry_run => 1, planned => [], errors => [] },
        };
    }
}

{
    package MB268CmdObject;
    sub new { my ($class) = @_; return bless { name => 'safe_from_hash' }, $class; }
    sub name { return [ 'bad_from_method' ]; }
}

my $P = 'Mediabot::Plugin::ScriptDryRun';

my $bot = MB268Bot->new(MB268Conf->new(
    'SCRIPT_DRYRUN_SCRIPT' => 'examples/hello_perl.pl',
));
my $plugin = $P->register($bot);

ok(!$plugin->command_allowed([ 'bad' ]),
    'ARRAY ref command is not accepted by fallback SCRIPT');
ok(!$plugin->command_allowed({ bad => 1 }),
    'HASH ref command is not accepted by fallback SCRIPT');
ok(!$plugin->_command_is_scoped([ 'hello' ]),
    'ARRAY ref command is never considered scoped');

my $before_calls = $bot->{calls};
my $result = $plugin->observe_public_command({
    command => [ 'bad' ],
    channel => '#teuk',
    nick    => 'Teuk',
});

ok(!defined $result,
    'observe_public_command ignores non-scalar command context');
is($bot->{calls}, $before_calls,
    'non-scalar command context does not run fallback script');
like($plugin->{last_error} // '', qr/not allowed|<empty>/,
    'non-scalar command context records a skip reason');

my $valid = $plugin->observe_public_command({
    command => 'hello',
    channel => '#teuk',
    nick    => 'Teuk',
});

ok(ref($valid) eq 'HASH' && $valid->{ok},
    'valid scalar command still reaches ScriptDryRun');
is($bot->{calls}, $before_calls + 1,
    'valid scalar command still runs the fallback script');

is(Mediabot::Plugin::ScriptDryRun::_ctx_command({ command => [ 'bad' ] }), undef,
    '_ctx_command rejects ARRAY command values');
is(Mediabot::Plugin::ScriptDryRun::_ctx_command({ cmd => { bad => 1 } }), undef,
    '_ctx_command rejects HASH cmd values');
is(Mediabot::Plugin::ScriptDryRun::_ctx_command({ command_obj => MB268CmdObject->new }), 'safe_from_hash',
    '_ctx_command ignores ref-returning command methods and falls back to scalar hash name');

my $src = do {
    open my $fh, '<', 'Mediabot/Plugin/ScriptDryRun.pm'
        or die "cannot open ScriptDryRun.pm: $!";
    local $/;
    <$fh>;
};

like($src, qr/mb268-B1/,
    'ScriptDryRun source contains mb268 command scalar marker');
unlike($src, qr/system\s*\(|qx\//,
    'mb268 command scalar guard does not introduce shell execution');
