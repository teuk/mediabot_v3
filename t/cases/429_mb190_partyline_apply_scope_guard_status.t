# t/cases/429_mb190_partyline_apply_scope_guard_status.t
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

    my $warning = 'ACTION_MODE=apply requires COMMANDS or ROUTES when APPLY_REQUIRE_SCOPE is enabled';

    my $plugin = FakeScriptDryRunPlugin->new(
        script_path       => 'fallback.pl',
        observed_public   => 3,
        skipped_public    => 1,
        action_mode       => 'apply',
        allow_irc         => 1,
        scope_guard       => 1,
        scope_restricted  => 0,
        scope_warning     => $warning,
        last_error        => $warning,
        last_result       => undef,
    );

    my $party = bless {
        bot => FakeBot->new(FakePluginManager->new($plugin)),
    }, 'Mediabot::Partyline';

    my $status_stream = FakeStream->new;
    $party->_cmd_scriptdryrun($status_stream, 1, 'status');
    my $status = $status_stream->out;

    $assert->($status =~ /apply_require_scope: yes/,
        'status output reports apply_require_scope yes');
    $assert->($status =~ /apply_scope_restricted: no/,
        'status output reports unrestricted apply scope');
    $assert->($status =~ /apply_scope_warning: ACTION_MODE=apply requires COMMANDS or ROUTES/,
        'status output reports apply scope warning');

    my $last_stream = FakeStream->new;
    $party->_cmd_scriptdryrun($last_stream, 1, 'last');
    my $last = $last_stream->out;

    $assert->($last =~ /apply_require_scope: yes/,
        'last output reports apply_require_scope yes');
    $assert->($last =~ /apply_scope_restricted: no/,
        'last output reports unrestricted apply scope');
    $assert->($last =~ /apply_scope_warning: ACTION_MODE=apply requires COMMANDS or ROUTES/,
        'last output reports apply scope warning');

    my $config_stream = FakeStream->new;
    $party->_cmd_scriptdryrun($config_stream, 1, 'config');
    my $config = $config_stream->out;

    $assert->($config =~ /apply scope guard keys:/,
        'config output has apply scope guard section');
    $assert->($config =~ /plugins\.ScriptDryRun\.APPLY_REQUIRE_SCOPE/,
        'config output lists plugins.ScriptDryRun.APPLY_REQUIRE_SCOPE');
    $assert->($config =~ /SCRIPT_DRYRUN_APPLY_REQUIRE_SCOPE/,
        'config output lists flat SCRIPT_DRYRUN_APPLY_REQUIRE_SCOPE');
    $assert->($config =~ /ACTION_MODE=apply requires COMMANDS or ROUTES/,
        'config output explains apply scope guard');

    my $restricted_plugin = FakeScriptDryRunPlugin->new(
        script_path       => 'fallback.pl',
        action_mode       => 'apply',
        allow_irc         => 1,
        scope_guard       => 1,
        scope_restricted  => 1,
        scope_warning     => undef,
        last_result       => undef,
    );

    my $restricted_party = bless {
        bot => FakeBot->new(FakePluginManager->new($restricted_plugin)),
    }, 'Mediabot::Partyline';

    my $restricted_stream = FakeStream->new;
    $restricted_party->_cmd_scriptdryrun($restricted_stream, 1, 'status');
    my $restricted = $restricted_stream->out;

    $assert->($restricted =~ /apply_require_scope: yes/,
        'restricted status reports apply_require_scope yes');
    $assert->($restricted =~ /apply_scope_restricted: yes/,
        'restricted status reports restricted scope');
    $assert->($restricted !~ /apply_scope_warning:/,
        'restricted status has no apply scope warning');

    my $disabled_plugin = FakeScriptDryRunPlugin->new(
        script_path       => 'fallback.pl',
        action_mode       => 'dry-run',
        allow_irc         => 0,
        scope_guard       => 0,
        scope_restricted  => 0,
        scope_warning     => undef,
        last_result       => undef,
    );

    my $disabled_party = bless {
        bot => FakeBot->new(FakePluginManager->new($disabled_plugin)),
    }, 'Mediabot::Partyline';

    my $disabled_stream = FakeStream->new;
    $disabled_party->_cmd_scriptdryrun($disabled_stream, 1, 'status');
    my $disabled = $disabled_stream->out;

    $assert->($disabled =~ /apply_require_scope: no/,
        'disabled status reports apply_require_scope no');

    my $pl_file = File::Spec->catfile($root, 'Mediabot', 'Partyline.pm');
    open my $fh, '<', $pl_file
        or do { $assert->(0, "cannot open Partyline.pm: $!"); return; };
    my $src = do { local $/; <$fh> };
    close $fh;

    $assert->($src =~ /mb190-B1: expose ScriptDryRun apply-scope guard state/,
        'Partyline source contains mb190 marker');
    $assert->($src =~ /apply_require_scope/,
        'Partyline source reads apply_require_scope');
    $assert->($src =~ /apply_scope_is_restricted/,
        'Partyline source reads apply_scope_is_restricted');
    $assert->($src =~ /apply_scope_warning/,
        'Partyline source reads apply_scope_warning');
    $assert->($src !~ /_cmd_scriptdryrun.*apply_actions/s,
        'Partyline ScriptDryRun status does not apply actions');
    $assert->($src !~ /_cmd_scriptdryrun.*run_script_actions_dry/s,
        'Partyline ScriptDryRun status does not run script pipeline');
    $assert->($src !~ /_cmd_scriptdryrun.*send_privmsg/s,
        'Partyline ScriptDryRun status does not send IRC messages');
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
