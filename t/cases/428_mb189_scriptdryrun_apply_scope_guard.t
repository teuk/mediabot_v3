# t/cases/428_mb189_scriptdryrun_apply_scope_guard.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;
use File::Path qw(make_path);
use JSON::PP qw(decode_json encode_json);

{
    package GuardConf;
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


# mb228-B2: ScriptDryRun emits internal observability logs.  For scope-guard
# assertions, count only the external script's own log action payload.
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
            text   => 'scope-guard:' . ($payload->{data}{command} || '')
        },
        {
            type  => 'log',
            level => 'info',
            text  => 'scope-guard-log'
        }
    ]
});
EOS
    close $fh;
}

my $make_bot = sub {
    my (%conf) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');
    my $tmp = File::Spec->catdir($root, 't', 'tmp_mb189_scripts');
    make_path($tmp);
    write_script(File::Spec->catfile($tmp, 'scope_ok.pl'));

    my $irc = FakeIRC->new;
    my $logger = FakeLogger->new;

    my $bot = Mediabot->new({
        conf => GuardConf->new(%conf),
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

    my ($bot_guarded, $irc_guarded, $logger_guarded) = $make_bot->(
        'plugins.ScriptDryRun.SCRIPT'              => 'scope_ok.pl',
        'plugins.ScriptDryRun.ACTION_MODE'         => 'apply',
        'plugins.ScriptDryRun.ALLOW_IRC'           => 'yes',
        'plugins.ScriptDryRun.APPLY_REQUIRE_SCOPE' => 'yes',
    );

    $bot_guarded->plugin_manager->load_perl_module('Mediabot::Plugin::ScriptDryRun');
    my $guarded = $bot_guarded->plugin_manager->object_for('Mediabot::Plugin::ScriptDryRun');

    $assert->($guarded->action_mode eq 'apply' && $guarded->allow_irc,
        'guarded plugin is in apply mode with allow_irc');
    $assert->($guarded->apply_require_scope,
        'APPLY_REQUIRE_SCOPE truthy config is enabled');
    $assert->(!$guarded->apply_scope_is_restricted,
        'fallback SCRIPT alone is not considered restricted scope');
    $assert->($guarded->apply_scope_warning =~ /requires COMMANDS or ROUTES/,
        'apply_scope_warning explains missing COMMANDS/ROUTES');

    $bot_guarded->events->emit_report('public_command_observed', {
        channel => '#teuk',
        nick    => 'Te[u]K',
        command => 'demo',
        args    => [],
    });

    $assert->(!$guarded->last_result,
        'guarded unscoped apply mode does not run script pipeline');
    $assert->($guarded->last_error =~ /requires COMMANDS or ROUTES/,
        'guarded unscoped apply mode records explicit error');
    $assert->($guarded->skipped_public == 1,
        'guarded unscoped apply mode increments skipped_public');
    $assert->(@{ $irc_guarded->sent } == 0,
        'guarded unscoped apply mode sends no IRC messages');
    $assert->(count_logger_text($logger_guarded, 'scope-guard-log') == 0,
        'guarded unscoped apply mode applies no script log actions');

    my ($bot_commands, $irc_commands, $logger_commands) = $make_bot->(
        'plugins.ScriptDryRun.SCRIPT'              => 'scope_ok.pl',
        'plugins.ScriptDryRun.COMMANDS'            => 'demo',
        'plugins.ScriptDryRun.ACTION_MODE'         => 'apply',
        'plugins.ScriptDryRun.ALLOW_IRC'           => 'yes',
        'plugins.ScriptDryRun.APPLY_REQUIRE_SCOPE' => 'yes',
    );

    $bot_commands->plugin_manager->load_perl_module('Mediabot::Plugin::ScriptDryRun');
    my $commands = $bot_commands->plugin_manager->object_for('Mediabot::Plugin::ScriptDryRun');

    $assert->($commands->apply_scope_is_restricted,
        'COMMANDS makes apply scope restricted');

    $bot_commands->events->emit_report('public_command_observed', {
        channel => '#teuk',
        nick    => 'Te[u]K',
        command => 'demo',
        args    => [],
    });

    $assert->($commands->last_result && $commands->last_result->{ok},
        'guarded apply mode with COMMANDS runs pipeline');
    $assert->(@{ $irc_commands->sent } == 1,
        'guarded apply mode with COMMANDS sends one IRC message');
    $assert->(count_logger_text($logger_commands, 'scope-guard-log') == 1,
        'guarded apply mode with COMMANDS applies script log action');

    my ($bot_routes, $irc_routes, $logger_routes) = $make_bot->(
        'plugins.ScriptDryRun.ROUTES'              => 'demo=scope_ok.pl',
        'plugins.ScriptDryRun.ACTION_MODE'         => 'apply',
        'plugins.ScriptDryRun.ALLOW_IRC'           => 'yes',
        'plugins.ScriptDryRun.APPLY_REQUIRE_SCOPE' => 'yes',
    );

    $bot_routes->plugin_manager->load_perl_module('Mediabot::Plugin::ScriptDryRun');
    my $routes = $bot_routes->plugin_manager->object_for('Mediabot::Plugin::ScriptDryRun');

    $assert->($routes->apply_scope_is_restricted,
        'ROUTES makes apply scope restricted');

    $bot_routes->events->emit_report('public_command_observed', {
        channel => '#teuk',
        nick    => 'Te[u]K',
        command => 'demo',
        args    => [],
    });

    $assert->($routes->last_result && $routes->last_result->{ok},
        'guarded apply mode with ROUTES runs pipeline');
    $assert->(@{ $irc_routes->sent } == 1,
        'guarded apply mode with ROUTES sends one IRC message');
    $assert->(count_logger_text($logger_routes, 'scope-guard-log') == 1,
        'guarded apply mode with ROUTES applies script log action');

    my ($bot_legacy, $irc_legacy, $logger_legacy) = $make_bot->(
        'plugins.ScriptDryRun.SCRIPT'      => 'scope_ok.pl',
        'plugins.ScriptDryRun.ACTION_MODE' => 'apply',
        'plugins.ScriptDryRun.ALLOW_IRC'   => 'yes',
    );

    $bot_legacy->plugin_manager->load_perl_module('Mediabot::Plugin::ScriptDryRun');
    my $legacy = $bot_legacy->plugin_manager->object_for('Mediabot::Plugin::ScriptDryRun');

    # A3 (mb225): APPLY_REQUIRE_SCOPE now defaults to ENABLED. An unscoped
    # apply-mode config (SCRIPT only, no COMMANDS/ROUTES) is therefore refused
    # by the scope guard by default.
    $assert->($legacy->apply_require_scope,
        'APPLY_REQUIRE_SCOPE defaults to enabled (A3 mb225 security default)');

    $bot_legacy->events->emit_report('public_command_observed', {
        channel => '#teuk',
        nick    => 'Te[u]K',
        command => 'demo',
        args    => [],
    });

    $assert->(!($legacy->last_result && $legacy->last_result->{ok}),
        'unscoped apply mode no longer runs the pipeline by default (A3 mb225)');
    $assert->(@{ $irc_legacy->sent } == 0,
        'unscoped apply mode no longer sends IRC by default (A3 mb225)');
    $assert->($legacy->last_error && $legacy->last_error =~ /requires COMMANDS or ROUTES/,
        'unscoped apply mode records the scope-guard error by default (A3 mb225)');

    my $src_file = File::Spec->catfile($root, 'Mediabot', 'Plugin', 'ScriptDryRun.pm');
    open my $sfh, '<', $src_file
        or do { $assert->(0, "cannot open ScriptDryRun.pm: $!"); return; };
    my $src = do { local $/; <$sfh> };
    close $sfh;

    $assert->($src =~ /mb189-B1\b.*optional extra safety gate/,
        'ScriptDryRun source documents the mb189 apply-scope guard');
    $assert->($src =~ /APPLY_REQUIRE_SCOPE/,
        'ScriptDryRun source documents APPLY_REQUIRE_SCOPE keys');
    $assert->($src =~ /apply_scope_warning/,
        'ScriptDryRun source contains apply_scope_warning helper');
    $assert->($src !~ /dbh->|prepare\(|INSERT|UPDATE|DELETE|system\s*\(|qx\//,
        'ScriptDryRun apply scope guard does not touch DB or shell');
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
