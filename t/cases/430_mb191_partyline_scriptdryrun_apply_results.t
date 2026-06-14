# t/cases/430_mb191_partyline_scriptdryrun_apply_results.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

{
    package FakeStream;
    sub new { bless { out => '' }, shift }
    sub write { my ($self, $text) = @_; $self->{out} .= $text; return 1; }
    sub out { return $_[0]->{out}; }
}

{
    package FakePluginManager;
    sub new { my ($class, $plugin) = @_; bless { plugin => $plugin }, $class }
    sub object_for {
        my ($self, $name) = @_;
        return $self->{plugin} if $name eq 'Mediabot::Plugin::ScriptDryRun';
        return undef;
    }
}

{
    package FakeBot;
    sub new { my ($class, $pm) = @_; bless { pm => $pm }, $class }
    sub plugin_manager { return $_[0]->{pm}; }
}

{
    package FakeScriptDryRunPlugin;
    sub new { my ($class, %args) = @_; return bless \%args, $class; }
    sub script_path { return $_[0]->{script_path}; }
    sub observed_public { return $_[0]->{observed_public} || 0; }
    sub skipped_public { return $_[0]->{skipped_public} || 0; }
    sub filtered_public { return $_[0]->{filtered_public} || 0; }
    sub command_filter_enabled { return $_[0]->{filter_enabled} ? 1 : 0; }
    sub command_filter_list { return @{ $_[0]->{filter_list} || [] }; }
    sub command_routes_enabled { return $_[0]->{routes_enabled} ? 1 : 0; }
    sub command_route_list { return @{ $_[0]->{route_list} || [] }; }
    sub command_routes { return $_[0]->{route_map} || {}; }
    sub action_mode { return $_[0]->{action_mode} || 'dry-run'; }
    sub allow_irc { return $_[0]->{allow_irc} ? 1 : 0; }
    sub apply_require_scope { return $_[0]->{scope_guard} ? 1 : 0; }
    sub apply_scope_is_restricted { return $_[0]->{scope_restricted} ? 1 : 0; }
    sub apply_scope_warning { return $_[0]->{scope_warning}; }
    sub last_error { return $_[0]->{last_error}; }
    sub last_result { return $_[0]->{last_result}; }
}

my $case = sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');
    unshift @INC, $root;

    eval { require Mediabot::Partyline; 1 }
        or do { $assert->(0, "cannot load Mediabot::Partyline: $@"); return; };

    my $plugin = FakeScriptDryRunPlugin->new(
        script_path       => 'examples/hello_perl.pl',
        observed_public   => 5,
        skipped_public    => 0,
        action_mode       => 'apply',
        allow_irc         => 1,
        scope_guard       => 1,
        scope_restricted  => 1,
        last_result       => {
            ok      => 0,
            dry_run => 0,
            script_result => {
                ok        => 1,
                timeout   => 0,
                exit_code => 0,
            },
            action_plan => {
                ok          => 1,
                applied_ok  => 0,
                planned     => [
                    { type => 'reply', target => '#teuk', text => 'hello from apply mode' },
                    { type => 'log', level => 'info', text => 'hello log' },
                ],
                errors       => [],
                applied      => [
                    { index => 1, type => 'log' },
                ],
                apply_errors => [
                    { index => 0, type => 'reply', error => 'irc actions require allow_irc' },
                ],
            },
        },
    );

    my $party = bless {
        bot => FakeBot->new(FakePluginManager->new($plugin)),
    }, 'Mediabot::Partyline';

    my $status_stream = FakeStream->new;
    $party->_cmd_scriptdryrun($status_stream, 1, 'status');
    my $status = $status_stream->out;

    $assert->($status =~ /applied_ok: no/,
        'status output reports applied_ok');
    $assert->($status =~ /applied_actions: 1/,
        'status output reports applied action count');
    $assert->($status =~ /apply_errors: 1/,
        'status output reports apply error count');

    my $last_stream = FakeStream->new;
    $party->_cmd_scriptdryrun($last_stream, 1, 'last');
    my $last = $last_stream->out;

    $assert->($last =~ /applied_ok: no/,
        'last output reports applied_ok');
    $assert->($last =~ /applied_actions:/,
        'last output contains applied_actions section');
    $assert->($last =~ /index=1 type=log/,
        'last output reports applied log action');
    $assert->($last =~ /apply_errors:/,
        'last output contains apply_errors section');
    $assert->($last =~ /index=0 type=reply error=irc actions require allow_irc/,
        'last output reports apply error details');

    my $dry_plugin = FakeScriptDryRunPlugin->new(
        script_path       => 'examples/hello_perl.pl',
        action_mode       => 'dry-run',
        last_result       => {
            ok      => 1,
            dry_run => 1,
            script_result => {
                ok        => 1,
                timeout   => 0,
                exit_code => 0,
            },
            action_plan => {
                ok      => 1,
                planned => [
                    { type => 'reply', target => '#teuk', text => 'dry run only' },
                ],
                errors  => [],
            },
        },
    );

    my $dry_party = bless {
        bot => FakeBot->new(FakePluginManager->new($dry_plugin)),
    }, 'Mediabot::Partyline';

    my $dry_stream = FakeStream->new;
    $dry_party->_cmd_scriptdryrun($dry_stream, 1, 'status');
    my $dry_status = $dry_stream->out;

    $assert->($dry_status !~ /applied_ok:/,
        'dry-run status without apply result does not print applied_ok');
    $assert->($dry_status !~ /apply_errors: /,
        'dry-run status without apply result does not print apply_errors count');

    my $pl_file = File::Spec->catfile($root, 'Mediabot', 'Partyline.pm');
    open my $fh, '<', $pl_file
        or do { $assert->(0, "cannot open Partyline.pm: $!"); return; };
    my $src = do { local $/; <$fh> };
    close $fh;

    $assert->($src =~ /mb191-B1: expose ScriptActionRunner apply results/,
        'Partyline source contains mb191 marker');
    $assert->($src =~ /applied_ok/,
        'Partyline source reads applied_ok');
    $assert->($src =~ /apply_errors/,
        'Partyline source reads apply_errors');
    $assert->($src =~ /applied_actions/,
        'Partyline source prints applied_actions');
    $assert->($src !~ /_cmd_scriptdryrun.*apply_actions/s,
        'Partyline ScriptDryRun status still does not apply actions');
    $assert->($src !~ /_cmd_scriptdryrun.*run_script_actions_dry/s,
        'Partyline ScriptDryRun status still does not run script pipeline');
    $assert->($src !~ /_cmd_scriptdryrun.*send_privmsg/s,
        'Partyline ScriptDryRun status still does not send IRC messages');
};

if (caller) { return $case; }

my $tests = 0;
my $fail  = 0;

my $assert = sub {
    my ($ok, $name) = @_;
    $tests++;
    $name = 'unnamed assertion' unless defined $name && $name ne '';

    if ($ok) {
        print "ok $tests - $name\n";
    }
    else {
        print "not ok $tests - $name\n";
        $fail++;
    }
};

$case->($assert);
print "1..$tests\n";
exit($fail ? 1 : 0);
