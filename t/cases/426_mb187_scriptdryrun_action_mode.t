# t/cases/426_mb187_scriptdryrun_action_mode.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;
use File::Path qw(make_path);
use JSON::PP qw(decode_json encode_json);

{
    package ModeConf;
    sub new { my ($class, %data) = @_; return bless \%data, $class; }
    sub get { my ($self, $key) = @_; return $self->{$key}; }
}

{
    package FakeIRC;
    sub new { bless { sent => [] }, shift }
    sub send_message {
        my ($self, @args) = @_;
        push @{ $self->{sent} }, \@args;
        return 1;
    }
    sub sent { return $_[0]->{sent}; }
}

{
    package FakeLogger;
    sub new { bless { entries => [] }, shift }
    sub info {
        my ($self, $text) = @_;
        push @{ $self->{entries} }, [ 'info', $text ];
        return 1;
    }
    sub log {
        my ($self, $level, $text) = @_;
        push @{ $self->{entries} }, [ $level, $text ];
        return 1;
    }
    sub entries { return $_[0]->{entries}; }
}


# mb228-B1: ScriptDryRun now emits internal observability logs (accepted route,
# script_result, action_plan).  These tests must verify whether the script's
# own log action was applied, not count every logger entry.
sub count_logger_text {
    my ($logger, $wanted) = @_;
    return 0 unless $logger && $logger->can('entries');

    my $count = 0;
    for my $entry (@{ $logger->entries || [] }) {
        next unless ref($entry) eq 'ARRAY';
        my $text = $entry->[1];
        $count++ if defined $text && $text eq $wanted;
    }

    return $count;
}

sub write_script {
    my ($path) = @_;
    open my $fh, '>', $path or die "cannot write $path: $!";
    print {$fh} <<'EOS';
use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);
my $in = do { local $/; <STDIN> };
my $payload = decode_json($in);
print encode_json({
    actions => [
        {
            type   => 'reply',
            target => $payload->{data}{channel},
            text   => 'apply-mode:' . ($payload->{data}{command} || '')
        },
        {
            type  => 'log',
            level => 'info',
            text  => 'apply-mode-log'
        }
    ]
});
EOS
    close $fh;
}

my $make_bot = sub {
    my (%conf) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');
    my $tmp = File::Spec->catdir($root, 't', 'tmp_mb187_scripts');
    make_path($tmp);
    write_script(File::Spec->catfile($tmp, 'mode_ok.pl'));

    my $irc = FakeIRC->new;
    my $logger = FakeLogger->new;

    my $bot = Mediabot->new({
        conf => ModeConf->new(%conf),
    });

    $bot->{irc} = $irc;
    $bot->{logger} = $logger;
    $bot->{script_runner} = Mediabot::ScriptRunner->new(
        bot              => $bot,
        script_dir       => $tmp,
        timeout          => 3,
        max_stdout_bytes => 8192,
    );
    $bot->{script_action_runner} = Mediabot::ScriptActionRunner->new(
        bot             => $bot,
        max_text_length => 400,
    );

    return ($bot, $irc, $logger);
};

my $case = sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');
    unshift @INC, $root;

    eval { require 'Mediabot/Mediabot.pm'; 1 }
        or do { $assert->(0, "cannot load Mediabot/Mediabot.pm: $@"); return; };

    my ($bot_dry, $irc_dry, $logger_dry) = $make_bot->(
        'plugins.ScriptDryRun.SCRIPT' => 'mode_ok.pl',
    );

    $bot_dry->plugin_manager->load_perl_module('Mediabot::Plugin::ScriptDryRun');
    my $dry_plugin = $bot_dry->plugin_manager->object_for('Mediabot::Plugin::ScriptDryRun');

    $assert->($dry_plugin->action_mode eq 'dry-run',
        'missing ACTION_MODE defaults to dry-run');
    $assert->(!$dry_plugin->allow_irc,
        'missing ALLOW_IRC defaults to false');

    $bot_dry->events->emit_report('public_command_observed', {
        channel => '#teuk',
        nick    => 'Te[u]K',
        command => 'demo',
        args    => [],
    });

    my $dry_result = $dry_plugin->last_result;
    $assert->($dry_result->{dry_run},
        'default action mode keeps dry-run result');
    $assert->(@{ $irc_dry->sent } == 0,
        'default dry-run mode sends no IRC messages');
    $assert->(count_logger_text($logger_dry, 'apply-mode-log') == 0,
        'default dry-run mode does not apply script log action');

    my ($bot_apply_no_irc, $irc_no, $logger_no) = $make_bot->(
        'plugins.ScriptDryRun.SCRIPT'              => 'mode_ok.pl',
        'plugins.ScriptDryRun.ACTION_MODE'         => 'apply',
        # mb226: APPLY_REQUIRE_SCOPE defaults to enabled since A3 (mb225); this
        # block exercises a bare-SCRIPT apply, so it opts out explicitly.
        'plugins.ScriptDryRun.APPLY_REQUIRE_SCOPE' => 'no',
    );

    $bot_apply_no_irc->plugin_manager->load_perl_module('Mediabot::Plugin::ScriptDryRun');
    my $apply_no_plugin = $bot_apply_no_irc->plugin_manager->object_for('Mediabot::Plugin::ScriptDryRun');

    $assert->($apply_no_plugin->action_mode eq 'apply',
        'ACTION_MODE=apply enables apply mode');
    $assert->(!$apply_no_plugin->allow_irc,
        'apply mode still has allow_irc disabled by default');

    $bot_apply_no_irc->events->emit_report('public_command_observed', {
        channel => '#teuk',
        nick    => 'Te[u]K',
        command => 'demo',
        args    => [],
    });

    my $apply_no_result = $apply_no_plugin->last_result;
    $assert->(!$apply_no_result->{dry_run},
        'apply mode returns non-dry-run result');
    $assert->(!$apply_no_result->{ok},
        'apply mode without allow_irc is not fully OK because reply is gated');
    $assert->(@{ $irc_no->sent } == 0,
        'apply mode without allow_irc sends no IRC messages');
    $assert->(count_logger_text($logger_no, 'apply-mode-log') == 1,
        'apply mode without allow_irc applies script log action');

    my ($bot_apply_irc, $irc_yes, $logger_yes) = $make_bot->(
        'plugins.ScriptDryRun.SCRIPT'              => 'mode_ok.pl',
        'plugins.ScriptDryRun.ACTION_MODE'         => 'apply',
        'plugins.ScriptDryRun.ALLOW_IRC'           => 'yes',
        # mb226: bare-SCRIPT apply opts out of the A3 (mb225) scope requirement.
        'plugins.ScriptDryRun.APPLY_REQUIRE_SCOPE' => 'no',
    );

    $bot_apply_irc->plugin_manager->load_perl_module('Mediabot::Plugin::ScriptDryRun');
    my $apply_yes_plugin = $bot_apply_irc->plugin_manager->object_for('Mediabot::Plugin::ScriptDryRun');

    $assert->($apply_yes_plugin->action_mode eq 'apply' && $apply_yes_plugin->allow_irc,
        'ACTION_MODE=apply with ALLOW_IRC=yes enables IRC application');

    $bot_apply_irc->events->emit_report('public_command_observed', {
        channel => '#teuk',
        nick    => 'Te[u]K',
        command => 'demo',
        args    => [],
    });

    my $apply_yes_result = $apply_yes_plugin->last_result;
    $assert->(!$apply_yes_result->{dry_run} && $apply_yes_result->{ok},
        'apply mode with allow_irc returns OK non-dry-run result');
    $assert->(@{ $irc_yes->sent } == 1,
        'apply mode with allow_irc sends one IRC message');
    $assert->($irc_yes->sent->[0][0] eq 'PRIVMSG' && $irc_yes->sent->[0][2] eq '#teuk',
        'apply mode with allow_irc sends PRIVMSG to channel');
    $assert->(count_logger_text($logger_yes, 'apply-mode-log') == 1,
        'apply mode with allow_irc applies script log action');

    my ($bot_bad, $irc_bad, $logger_bad) = $make_bot->(
        'plugins.ScriptDryRun.SCRIPT'      => 'mode_ok.pl',
        'plugins.ScriptDryRun.ACTION_MODE' => 'bogus',
        'plugins.ScriptDryRun.ALLOW_IRC'   => 'on',
    );

    $bot_bad->plugin_manager->load_perl_module('Mediabot::Plugin::ScriptDryRun');
    my $bad_plugin = $bot_bad->plugin_manager->object_for('Mediabot::Plugin::ScriptDryRun');

    $assert->($bad_plugin->action_mode eq 'dry-run',
        'invalid ACTION_MODE falls back to dry-run');
    $assert->($bad_plugin->allow_irc,
        'ALLOW_IRC truthy parsing works independently of action mode');

    my $src_file = File::Spec->catfile($root, 'Mediabot', 'Plugin', 'ScriptDryRun.pm');
    open my $sfh, '<', $src_file
        or do { $assert->(0, "cannot open ScriptDryRun.pm: $!"); return; };
    my $src = do { local $/; <$sfh> };
    close $sfh;

    $assert->($src =~ /mb187-B1: explicit action mode gate/,
        'ScriptDryRun source contains mb187 marker');
    $assert->($src =~ /ACTION_MODE/,
        'ScriptDryRun source documents ACTION_MODE keys');
    $assert->($src =~ /ALLOW_IRC/,
        'ScriptDryRun source documents ALLOW_IRC keys');
    $assert->($src =~ /apply_actions/,
        'ScriptDryRun source can call ScriptActionRunner apply_actions');
    $assert->($src !~ /dbh->|prepare\(|INSERT|UPDATE|DELETE|system\s*\(|qx\//,
        'ScriptDryRun action mode does not touch DB or shell');
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
