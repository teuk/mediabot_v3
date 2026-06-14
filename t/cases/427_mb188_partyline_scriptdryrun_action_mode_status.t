# t/cases/427_mb188_partyline_scriptdryrun_action_mode_status.t
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
        script_path     => 'examples/hello_perl.pl',
        observed_public => 4,
        skipped_public  => 0,
        filtered_public => 0,
        filter_enabled  => 1,
        filter_list     => [ 'hello' ],
        routes_enabled  => 1,
        route_list      => [ 'hello' ],
        route_map       => { hello => 'examples/hello_perl.pl' },
        action_mode     => 'apply',
        allow_irc       => 1,
        last_result     => {
            ok      => 1,
            dry_run => 0,
            script_result => {
                ok        => 1,
                timeout   => 0,
                exit_code => 0,
            },
            action_plan => {
                ok         => 1,
                applied_ok => 1,
                planned    => [
                    { type => 'reply', target => '#teuk', text => 'hello apply mode' },
                ],
                errors       => [],
                applied      => [
                    { index => 0, type => 'reply', target => '#teuk' },
                ],
                apply_errors => [],
            },
        },
    );

    my $party = bless {
        bot => FakeBot->new(FakePluginManager->new($plugin)),
    }, 'Mediabot::Partyline';

    my $status_stream = FakeStream->new;
    $party->_cmd_scriptdryrun($status_stream, 1, 'status');
    my $status = $status_stream->out;

    $assert->($status =~ /action_mode: apply/,
        'status output reports apply action mode');
    $assert->($status =~ /allow_irc: yes/,
        'status output reports allow_irc yes');

    my $last_stream = FakeStream->new;
    $party->_cmd_scriptdryrun($last_stream, 1, 'last');
    my $last = $last_stream->out;

    $assert->($last =~ /action_mode: apply/,
        'last output reports apply action mode');
    $assert->($last =~ /allow_irc: yes/,
        'last output reports allow_irc yes');

    my $config_stream = FakeStream->new;
    $party->_cmd_scriptdryrun($config_stream, 1, 'config');
    my $config = $config_stream->out;

    $assert->($config =~ /action mode keys:/,
        'config output has action mode key section');
    $assert->($config =~ /plugins\.ScriptDryRun\.ACTION_MODE/,
        'config output lists plugins.ScriptDryRun.ACTION_MODE');
    $assert->($config =~ /SCRIPT_DRYRUN_ACTION_MODE/,
        'config output lists flat SCRIPT_DRYRUN_ACTION_MODE');
    $assert->($config =~ /allowed IRC keys:/,
        'config output has allowed IRC key section');
    $assert->($config =~ /plugins\.ScriptDryRun\.ALLOW_IRC/,
        'config output lists plugins.ScriptDryRun.ALLOW_IRC');
    $assert->($config =~ /SCRIPT_DRYRUN_ALLOW_IRC/,
        'config output lists flat SCRIPT_DRYRUN_ALLOW_IRC');
    $assert->($config =~ /IRC output requires: ACTION_MODE=apply and ALLOW_IRC=yes/,
        'config output explains double gate for IRC output');

    my $dry_plugin = FakeScriptDryRunPlugin->new(
        script_path     => 'examples/hello_perl.pl',
        action_mode     => 'dry-run',
        allow_irc       => 0,
        last_result     => undef,
    );

    my $dry_party = bless {
        bot => FakeBot->new(FakePluginManager->new($dry_plugin)),
    }, 'Mediabot::Partyline';

    my $dry_stream = FakeStream->new;
    $dry_party->_cmd_scriptdryrun($dry_stream, 1, 'status');
    my $dry = $dry_stream->out;

    $assert->($dry =~ /action_mode: dry-run/,
        'status output reports dry-run action mode');
    $assert->($dry =~ /allow_irc: no/,
        'status output reports allow_irc no');

    my $pl_file = File::Spec->catfile($root, 'Mediabot', 'Partyline.pm');
    open my $fh, '<', $pl_file
        or do { $assert->(0, "cannot open Partyline.pm: $!"); return; };
    my $src = do { local $/; <$fh> };
    close $fh;

    $assert->($src =~ /mb188-B1: expose ScriptDryRun ACTION_MODE/,
        'Partyline source contains mb188 marker');
    $assert->($src =~ /action_mode/,
        'Partyline source reads action_mode');
    $assert->($src =~ /allow_irc/,
        'Partyline source reads allow_irc');
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
