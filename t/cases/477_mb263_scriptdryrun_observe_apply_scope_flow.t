#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use Test::More tests => 19;
use lib '.';

BEGIN { use_ok('Mediabot::Plugin::ScriptDryRun') }

{
    package MB263::ScriptRunner;
    sub new { bless { calls => [] }, shift }
    sub run_script {
        my ($self, $path, $event, %data) = @_;
        push @{ $self->{calls} }, { path => $path, event => $event, data => \%data };
        return {
            ok       => 1,
            response => { ok => 1, actions => [] },
            actions  => [ { type => 'log', level => 'info', text => 'mb263 ok' } ],
            errors   => [],
        };
    }
}

{
    package MB263::ActionRunner;
    sub new { bless { calls => [] }, shift }
    sub apply_actions {
        my ($self, $script_result, $context, %opts) = @_;
        push @{ $self->{calls} }, { script_result => $script_result, context => $context, opts => \%opts };
        return {
            ok           => 1,
            applied_ok   => 1,
            dry_run      => 0,
            planned      => [ @{ $script_result->{actions} || [] } ],
            applied      => [ @{ $script_result->{actions} || [] } ],
            errors       => [],
            apply_errors => [],
        };
    }
}

{
    package MB263::Bot;
    sub new {
        my ($class) = @_;
        return bless {
            sr => MB263::ScriptRunner->new,
            ar => MB263::ActionRunner->new,
        }, $class;
    }
    sub run_script_actions_dry { die 'dry-run path must not be used in this apply-mode test' }
    sub script_runner { $_[0]->{sr} }
    sub script_action_runner { $_[0]->{ar} }
}

my $P = 'Mediabot::Plugin::ScriptDryRun';

my $mk = sub {
    my (%h) = @_;
    return bless {
        bot                 => $h{bot},
        action_mode         => 'apply',
        allow_irc           => 1,
        apply_require_scope => exists $h{require_scope} ? $h{require_scope} : 1,
        command_filter      => $h{filter} || {},
        command_routes      => $h{routes} || {},
        script_path         => $h{script},
        observed_public     => 0,
        skipped_public      => 0,
        filtered_public     => 0,
    }, $P;
};

{
    my $bot = MB263::Bot->new;
    my $plugin = $mk->(
        bot    => $bot,
        routes => { foo => 'foo.pl' },
        script => 'fallback.pl',
    );

    my %ctx = (
        command => 'foo',
        channel => '#teuk',
        nick    => 'Te[u]K',
        args    => [ 'hello' ],
    );

    my $result = $plugin->observe_public_command(\%ctx);

    ok(ref($result) eq 'HASH', 'routed apply command returns a result');
    ok($result->{ok}, 'routed apply command succeeds');
    ok($ctx{scriptdryrun_handled}, 'routed apply command is marked handled');
    is($plugin->last_error, undef, 'routed apply command leaves no last_error');
    is(scalar @{ $bot->{sr}->{calls} }, 1, 'routed apply command runs exactly one script');
    is($bot->{sr}->{calls}->[0]->{path}, 'foo.pl', 'routed apply command uses route script');
    is(scalar @{ $bot->{ar}->{calls} }, 1, 'routed apply command applies exactly once');
    ok($bot->{ar}->{calls}->[0]->{opts}->{apply}, 'routed apply command reaches apply mode');
}

{
    my $bot = MB263::Bot->new;
    my $plugin = $mk->(
        bot    => $bot,
        routes => { foo => 'foo.pl' },
        script => 'fallback.pl',
    );

    my %ctx = (
        command => 'bar',
        channel => '#teuk',
        nick    => 'Te[u]K',
        args    => [],
    );

    my $result = $plugin->observe_public_command(\%ctx);

    ok(!defined($result), 'unrouted fallback apply command is rejected by default');
    like($plugin->last_error || '', qr/current command/, 'unrouted fallback apply command reports current-command scope guard');
    ok(!$ctx{scriptdryrun_handled}, 'rejected fallback command is not marked handled');
    is(scalar @{ $bot->{sr}->{calls} }, 0, 'rejected fallback command does not run the fallback script');
    is(scalar @{ $bot->{ar}->{calls} }, 0, 'rejected fallback command applies no actions');
}

{
    my $bot = MB263::Bot->new;
    my $plugin = $mk->(
        bot           => $bot,
        require_scope => 0,
        routes        => { foo => 'foo.pl' },
        script        => 'fallback.pl',
    );

    my %ctx = (
        command => 'bar',
        channel => '#teuk',
        nick    => 'Te[u]K',
        args    => [],
    );

    my $result = $plugin->observe_public_command(\%ctx);

    ok(ref($result) eq 'HASH' && $result->{ok}, 'explicit opt-out still allows fallback apply command');
    ok($ctx{scriptdryrun_handled}, 'explicit opt-out fallback apply command is owned to avoid double execution');
    is($bot->{sr}->{calls}->[0]->{path}, 'fallback.pl', 'explicit opt-out uses fallback script');
}

{
    open my $fh, '<', 'Mediabot/Plugin/ScriptDryRun.pm'
        or die "cannot open ScriptDryRun.pm: $!";
    local $/;
    my $src = <$fh>;

    ok($src =~ /apply_scope_warning\(\$command\)/,
        'observe_public_command passes the current command to apply_scope_warning');
    ok($src !~ /system\s*\(|qx\//,
        'mb263 observer flow guard does not introduce shell execution');
}
