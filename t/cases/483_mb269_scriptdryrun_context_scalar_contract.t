#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use Test::More tests => 23;
use lib '.';

BEGIN { use_ok('Mediabot::Plugin::ScriptDryRun') }

{
    package MB269Conf;
    sub new { my ($class, %data) = @_; return bless \%data, $class; }
    sub get { my ($self, $key) = @_; return $self->{$key}; }
}

{
    package MB269Bot;
    sub new { my ($class, $conf) = @_; return bless { conf => $conf, calls => 0, last_data => undef }, $class; }
    sub events { return undef; }
    sub run_script_actions_dry {
        my ($self, $script, $event, %data) = @_;
        $self->{calls}++;
        $self->{last_script} = $script;
        $self->{last_event}  = $event;
        $self->{last_data}   = \%data;
        return {
            ok            => 1,
            script_result => { ok => 1, response => { ok => 1, actions => [] } },
            action_plan   => { ok => 1, dry_run => 1, planned => [], errors => [] },
        };
    }
}

{
    package MB269CmdObject;
    sub new { my ($class) = @_; return bless { name => 'from_hash', args => [ 'hash_arg', { bad => 1 }, 'last' ] }, $class; }
    sub name { return [ 'bad_from_name_method' ]; }
    sub command { return { bad => 1 }; }
    sub cmd { return 'from_method'; }
    sub args { return [ 'method_arg', [ 'bad' ], 'tail' ]; }
}

my $P = 'Mediabot::Plugin::ScriptDryRun';

my $bot = MB269Bot->new(MB269Conf->new(
    'SCRIPT_DRYRUN_COMMANDS' => 'hello,from_method',
    'SCRIPT_DRYRUN_SCRIPT'   => 'examples/hello_perl.pl',
));
my $plugin = $P->register($bot);

is(Mediabot::Plugin::ScriptDryRun::_ctx_command({ command => [ 'bad' ], cmd => 'hello' }), 'hello',
    '_ctx_command ignores non-scalar command and falls back to scalar cmd');
is(Mediabot::Plugin::ScriptDryRun::_ctx_command({ command => { bad => 1 }, cmd => [ 'also_bad' ] }), undef,
    '_ctx_command rejects non-scalar command and cmd when no scalar fallback exists');
is(Mediabot::Plugin::ScriptDryRun::_ctx_command({ command_obj => MB269CmdObject->new }), 'from_method',
    '_ctx_command ignores ref-returning command object methods before scalar fallback');

is(Mediabot::Plugin::ScriptDryRun::_ctx_scalar_value({ channel => [ '#bad' ], target => '#fallback' }, 'channel', 'target'), '#fallback',
    '_ctx_scalar_value ignores non-scalar first field and uses scalar fallback');
is(Mediabot::Plugin::ScriptDryRun::_ctx_scalar_value({ nick => { bad => 1 }, sender => 'Teuk' }, 'nick', 'sender'), 'Teuk',
    '_ctx_scalar_value ignores HASH ref and uses sender fallback');
is(Mediabot::Plugin::ScriptDryRun::_ctx_scalar_value({ nick => [ 'bad' ], sender => { bad => 1 } }, 'nick', 'sender'), undef,
    '_ctx_scalar_value returns undef when all candidate values are refs');

is_deeply(Mediabot::Plugin::ScriptDryRun::_ctx_args({ args => [ 'one', [ 'bad' ], { bad => 1 }, undef, 'two', 0 ] }), [ 'one', 'two', '0' ],
    '_ctx_args keeps only defined scalar top-level args');
is_deeply(Mediabot::Plugin::ScriptDryRun::_ctx_args({ command_obj => MB269CmdObject->new }), [ 'method_arg', 'tail' ],
    '_ctx_args filters refs from command object args method');

my $result = $plugin->observe_public_command({
    command => [ 'bad' ],
    cmd     => 'hello',
    channel => [ '#bad' ],
    target  => '#teuk',
    nick    => { bad => 1 },
    sender  => 'Teuk',
    args    => [ 'alpha', [ 'bad' ], { bad => 1 }, 'omega' ],
});

ok(ref($result) eq 'HASH' && $result->{ok},
    'observe_public_command still runs when scalar command fallback exists');
is($bot->{calls}, 1,
    'observe_public_command runs exactly once');
is($bot->{last_data}->{command}, 'hello',
    'runtime payload uses scalar command fallback');
is($bot->{last_data}->{channel}, '#teuk',
    'runtime payload uses scalar channel/target fallback');
is($bot->{last_data}->{target}, '#teuk',
    'runtime payload target stays scalar');
is($bot->{last_data}->{nick}, 'Teuk',
    'runtime payload uses scalar nick/sender fallback');
is_deeply($bot->{last_data}->{args}, [ 'alpha', 'omega' ],
    'runtime payload args are scalar-only');

my $before = $bot->{calls};
my $skipped = $plugin->observe_public_command({
    command => [ 'bad' ],
    cmd     => { bad => 1 },
    channel => '#teuk',
    nick    => 'Teuk',
});

ok(!defined $skipped,
    'observe_public_command skips when command and fallback cmd are non-scalar');
is($bot->{calls}, $before,
    'non-scalar command values do not run the script');
like($plugin->last_error // '', qr/not allowed|<empty>/,
    'non-scalar command skip records a safe error');

my $src = do {
    open my $fh, '<', 'Mediabot/Plugin/ScriptDryRun.pm'
        or die "cannot open ScriptDryRun.pm: $!";
    local $/;
    <$fh>;
};

like($src, qr/mb269-B1/,
    'ScriptDryRun source contains mb269 command fallback marker');
like($src, qr/mb269-B2/,
    'ScriptDryRun source contains mb269 scalar context marker');
like($src, qr/mb269-B3/,
    'ScriptDryRun source contains mb269 args scalar marker');
unlike($src, qr/system\s*\(|qx\//,
    'mb269 context scalar guard does not introduce shell execution');
