# t/cases/419_mb180_partyline_scriptdryrun_status.t
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
    sub new {
        my ($class, %args) = @_;
        return bless \%args, $class;
    }
    sub script_path { return $_[0]->{script_path}; }
    sub observed_public { return $_[0]->{observed_public} || 0; }
    sub skipped_public { return $_[0]->{skipped_public} || 0; }
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
        script_path     => 'bridge_ok.pl',
        observed_public => 3,
        skipped_public  => 1,
        last_result     => {
            ok      => 1,
            dry_run => 1,
            script_result => {
                ok        => 1,
                timeout   => 0,
                exit_code => 0,
            },
            action_plan => {
                ok => 1,
                planned => [
                    { type => 'reply', target => '#teuk', text => 'hello from dry-run' },
                    { type => 'log', level => 'info', text => 'log line' },
                ],
                errors => [],
            },
        },
    );

    my $party = bless {
        bot => FakeBot->new(FakePluginManager->new($plugin)),
    }, 'Mediabot::Partyline';

    my $status_stream = FakeStream->new;
    $party->_cmd_scriptdryrun($status_stream, 1, undef);
    my $status = $status_stream->out;

    $assert->($status =~ /ScriptDryRun:/,
        'status output has ScriptDryRun header');
    $assert->($status =~ /loaded: yes/,
        'status output reports plugin loaded');
    $assert->($status =~ /script: bridge_ok\.pl/,
        'status output reports script path');
    $assert->($status =~ /observed_public: 3/,
        'status output reports observed_public');
    $assert->($status =~ /skipped_public: 1/,
        'status output reports skipped_public');
    $assert->($status =~ /last_result_ok: yes/,
        'status output reports last result OK');
    $assert->($status =~ /planned_actions: 2/,
        'status output reports planned action count');

    my $last_stream = FakeStream->new;
    $party->_cmd_scriptdryrun($last_stream, 1, 'last');
    my $last = $last_stream->out;

    $assert->($last =~ /planned_actions:/ && $last =~ /type=reply target=#teuk text=hello from dry-run/,
        'last output lists planned reply action');
    $assert->($last =~ /action_errors:\r?\n\s+none/,
        'last output reports no action errors');

    my $config_stream = FakeStream->new;
    $party->_cmd_scriptdryrun($config_stream, 1, 'config');
    my $config = $config_stream->out;

    $assert->($config =~ /ScriptDryRun config:/,
        'config output has header');
    $assert->($config =~ /plugins\.ScriptDryRun\.SCRIPT/,
        'config output lists config keys');
    $assert->($config =~ /action mode: dry-run only/,
        'config output states dry-run only');

    my $none_party = bless {
        bot => FakeBot->new(FakePluginManager->new(undef)),
    }, 'Mediabot::Partyline';

    my $none_stream = FakeStream->new;
    $none_party->_cmd_scriptdryrun($none_stream, 1, 'status');
    my $none = $none_stream->out;

    $assert->($none =~ /not loaded/,
        'status output reports plugin not loaded');

    my $bad_mode_stream = FakeStream->new;
    $party->_cmd_scriptdryrun($bad_mode_stream, 1, 'wat');
    my $bad_mode = $bad_mode_stream->out;

    $assert->($bad_mode =~ /Usage: \.scriptdryrun/,
        'invalid mode shows usage');

    my $pl_file = File::Spec->catfile($root, 'Mediabot', 'Partyline.pm');
    open my $fh, '<', $pl_file
        or do { $assert->(0, "cannot open Partyline.pm: $!"); return; };
    my $src = do { local $/; <$fh> };
    close $fh;

    $assert->($src =~ /mb180-B1: read-only partyline visibility for the ScriptDryRun bridge/,
        'Partyline source contains mb180 marker');
    $assert->($src =~ /\.scriptdryrun \[status\|last\|config\]/,
        'Partyline help contains .scriptdryrun');
    $assert->($src =~ /_cmd_scriptdryrun/,
        'Partyline has _cmd_scriptdryrun implementation');
    $assert->($src !~ /_cmd_scriptdryrun.*run_script_actions_dry/s,
        'Partyline ScriptDryRun status command does not execute script pipeline');
    $assert->($src !~ /_cmd_scriptdryrun.*send_privmsg/s,
        'Partyline ScriptDryRun status command does not send IRC messages');
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
