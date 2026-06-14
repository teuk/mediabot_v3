#!/usr/bin/env perl
use strict;
use warnings;
use lib '.';
use Test::More;

use Mediabot::Plugin::ScriptDryRun;

{
    package MB238FakeRunner;
    sub new { bless { calls => 0 }, shift }
    sub run_script {
        my ($self) = @_;
        $self->{calls}++;
        return {
            ok => 1,
            timeout => 0,
            exit_code => 0,
            response => { ok => 1, actions => [] },
        };
    }

    package MB238FakeActionRunner;
    sub new { bless { calls => 0 }, shift }
    sub apply_actions {
        my ($self) = @_;
        $self->{calls}++;
        return {
            ok => 1,
            dry_run => 0,
            planned => [],
            applied => [],
            errors => [],
            apply_errors => [],
            applied_ok => 1,
        };
    }

    package MB238FakeBot;
    sub new {
        my ($class, %args) = @_;
        return bless {
            conf => {
                'plugins.ScriptDryRun.ROUTES' => 'pyhello=examples/hello_python.py',
                'plugins.ScriptDryRun.ACTION_MODE' => 'apply',
                'plugins.ScriptDryRun.ALLOW_IRC' => 'yes',
                'plugins.ScriptDryRun.APPLY_REQUIRE_SCOPE' => 'yes',
            },
            %args,
        }, $class;
    }
    sub run_script_actions_dry { die 'dry path must not be used in apply-mode test' }
    sub script_runner { return $_[0]->{script_runner} }
    sub script_action_runner { return $_[0]->{script_action_runner} }
}

sub make_ctx {
    return {
        command => 'pyhello',
        channel => '#teuk',
        target  => '#teuk',
        nick    => 'Te[u]K',
        args    => [],
    };
}

my $bot_without_runner = MB238FakeBot->new(script_action_runner => MB238FakeActionRunner->new);
my $plugin_without_runner = Mediabot::Plugin::ScriptDryRun->register($bot_without_runner);
my $ctx1 = make_ctx();
my $r1 = $plugin_without_runner->observe_public_command($ctx1);

ok(!defined $r1, 'apply mode returns undef when ScriptRunner is missing');
ok(!exists $ctx1->{scriptdryrun_handled}, 'missing ScriptRunner does not mark command as handled');
is($plugin_without_runner->last_error, 'script runner is not initialized', 'missing ScriptRunner keeps explicit last_error');
is($plugin_without_runner->skipped_public, 1, 'missing ScriptRunner increments skipped counter');

my $runner = MB238FakeRunner->new;
my $bot_without_action_runner = MB238FakeBot->new(script_runner => $runner);
my $plugin_without_action_runner = Mediabot::Plugin::ScriptDryRun->register($bot_without_action_runner);
my $ctx2 = make_ctx();
my $r2 = $plugin_without_action_runner->observe_public_command($ctx2);

ok(!defined $r2, 'apply mode returns undef when ScriptActionRunner is missing');
ok(!exists $ctx2->{scriptdryrun_handled}, 'missing ScriptActionRunner does not mark command as handled');
is($plugin_without_action_runner->last_error, 'script action runner cannot apply actions', 'missing ScriptActionRunner keeps explicit last_error');
is($runner->{calls}, 0, 'missing ScriptActionRunner does not run external script first');

my $runner_ok = MB238FakeRunner->new;
my $action_ok = MB238FakeActionRunner->new;
my $bot_ok = MB238FakeBot->new(script_runner => $runner_ok, script_action_runner => $action_ok);
my $plugin_ok = Mediabot::Plugin::ScriptDryRun->register($bot_ok);
my $ctx3 = make_ctx();
my $r3 = $plugin_ok->observe_public_command($ctx3);

ok(ref($r3) eq 'HASH', 'apply mode still runs when both runners are available');
ok($ctx3->{scriptdryrun_handled}, 'successful apply-mode route still marks command as handled');
is($runner_ok->{calls}, 1, 'successful apply-mode route runs external script once');
is($action_ok->{calls}, 1, 'successful apply-mode route applies action plan once');
is($r3->{ok}, 1, 'successful apply-mode result remains ok');

my $src = do { local $/; open my $fh, '<', 'Mediabot/Plugin/ScriptDryRun.pm' or die $!; <$fh> };
like($src, qr/mb238-B1/, 'ScriptDryRun source contains mb238 apply runtime guard marker');
unlike($src, qr/`[^`]+`|\bqx\s*(?:\/|\(|\{)|\bsystem\s*(?:\(| )/, 'mb238 guard does not introduce shell execution');

done_testing();
