# t/cases/421_mb182_scriptdryrun_command_filter.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;
use File::Path qw(make_path);
use JSON::PP qw(decode_json encode_json);

{
    package FilterConf;
    sub new { my ($class, %data) = @_; return bless \%data, $class; }
    sub get { my ($self, $key) = @_; return $self->{$key}; }
}

my $case = sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');
    unshift @INC, $root;

    eval { require 'Mediabot/Mediabot.pm'; 1 }
        or do { $assert->(0, "cannot load Mediabot/Mediabot.pm: $@"); return; };

    my $tmp = File::Spec->catdir($root, 't', 'tmp_mb182_scripts');
    make_path($tmp);

    my $script = File::Spec->catfile($tmp, 'filter_ok.pl');
    open my $fh, '>', $script
        or do { $assert->(0, "cannot write filter script: $!"); return; };
    print {$fh} <<'EOS';
use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);
my $in = do { local $/; <STDIN> };
my $payload = decode_json($in);
print encode_json({
    actions => [
        {
            type => 'reply',
            text => 'filter:' . ($payload->{data}{command} || '')
        }
    ]
});
EOS
    close $fh;

    my $bot = Mediabot->new({
        conf => FilterConf->new(
            'plugins.ScriptDryRun.SCRIPT'   => 'filter_ok.pl',
            'plugins.ScriptDryRun.COMMANDS' => 'hello, scriptdemo  .prefixed',
        ),
    });

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

    my $entry = $bot->plugin_manager->load_perl_module('Mediabot::Plugin::ScriptDryRun');
    my $plugin = $bot->plugin_manager->object_for('Mediabot::Plugin::ScriptDryRun');

    $assert->($entry && $plugin,
        'ScriptDryRun plugin loads for command filter test');
    $assert->($plugin->command_filter_enabled,
        'ScriptDryRun command filter is enabled when COMMANDS is configured');

    my @filter = $plugin->command_filter_list;
    $assert->(join(',', @filter) eq 'hello,prefixed,scriptdemo',
        'ScriptDryRun command filter parses and normalizes configured commands');

    $assert->($plugin->command_allowed('hello'),
        'command_allowed accepts configured command');
    $assert->($plugin->command_allowed('.prefixed'),
        'command_allowed accepts command with leading trigger stripped');
    $assert->(!$plugin->command_allowed('version'),
        'command_allowed rejects unconfigured command');

    my $allowed_ctx = {
        channel => '#teuk',
        nick    => 'Te[u]K',
        command => 'hello',
        args    => [],
    };

    my $allowed_report = $bot->events->emit_report('public_command_observed', $allowed_ctx);

    $assert->($allowed_report->{ran} == 1,
        'EventBus runs ScriptDryRun listener for allowed command');
    $assert->($plugin->observed_public == 1,
        'allowed command increments observed_public');
    $assert->($plugin->filtered_public == 0,
        'allowed command does not increment filtered_public');

    my $allowed_result = $plugin->last_result;
    $assert->($allowed_result && $allowed_result->{ok},
        'allowed command runs dry-run script pipeline');
    $assert->($allowed_result->{action_plan}{planned}[0]{text} eq 'filter:hello',
        'allowed command result comes from external script');

    my $blocked_ctx = {
        channel => '#teuk',
        nick    => 'Te[u]K',
        command => 'version',
        args    => [],
    };

    my $blocked_report = $bot->events->emit_report('public_command_observed', $blocked_ctx);

    $assert->($blocked_report->{ran} == 1,
        'EventBus still runs listener for blocked command');
    $assert->($plugin->observed_public == 2,
        'blocked command increments observed_public');
    $assert->($plugin->filtered_public == 1,
        'blocked command increments filtered_public');
    $assert->($plugin->skipped_public == 1,
        'blocked command increments skipped_public');
    $assert->($plugin->last_error =~ /not allowed by ScriptDryRun filter/,
        'blocked command records filter skip error');
    $assert->($plugin->last_result == $allowed_result,
        'blocked command does not overwrite previous successful last_result');

    my $bot_no_filter = Mediabot->new({
        conf => FilterConf->new(
            'plugins.ScriptDryRun.SCRIPT' => 'filter_ok.pl',
        ),
    });

    $bot_no_filter->{script_runner} = Mediabot::ScriptRunner->new(
        bot              => $bot_no_filter,
        script_dir       => $tmp,
        timeout          => 3,
        max_stdout_bytes => 8192,
    );
    $bot_no_filter->{script_action_runner} = Mediabot::ScriptActionRunner->new(
        bot             => $bot_no_filter,
        max_text_length => 400,
    );

    $bot_no_filter->plugin_manager->load_perl_module('Mediabot::Plugin::ScriptDryRun');
    my $plugin_no_filter = $bot_no_filter->plugin_manager->object_for('Mediabot::Plugin::ScriptDryRun');

    $assert->(!$plugin_no_filter->command_filter_enabled,
        'missing COMMANDS keeps command filter disabled');
    $assert->($plugin_no_filter->command_allowed('anything'),
        'disabled command filter allows any command');

    my $src_file = File::Spec->catfile($root, 'Mediabot', 'Plugin', 'ScriptDryRun.pm');
    open my $sfh, '<', $src_file
        or do { $assert->(0, "cannot open ScriptDryRun.pm: $!"); return; };
    my $src = do { local $/; <$sfh> };
    close $sfh;

    $assert->($src =~ /mb182-B1: optional command allow-list/,
        'ScriptDryRun source contains mb182 marker');
    $assert->($src =~ /plugins\.ScriptDryRun\.COMMANDS/,
        'ScriptDryRun source documents COMMANDS config key');
    $assert->($src =~ /command_allowed/,
        'ScriptDryRun source contains command_allowed helper');
    $assert->($src !~ /send_privmsg|send_notice|send_message|dbh->|prepare\(|INSERT|UPDATE|DELETE/,
        'ScriptDryRun command filtering does not send IRC messages or touch DB');
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
