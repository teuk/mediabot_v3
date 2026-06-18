# t/cases/418_mb179_script_dryrun_plugin_bridge.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;
use File::Path qw(make_path);
use JSON::PP qw(decode_json encode_json);

{
    package BridgeConf;
    sub new { my ($class, %data) = @_; return bless \%data, $class; }
    sub get { my ($self, $key) = @_; return $self->{$key}; }
}

my $case = sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');
    unshift @INC, $root;

    eval { require 'Mediabot/Mediabot.pm'; 1 }
        or do { $assert->(0, "cannot load Mediabot/Mediabot.pm: $@"); return; };

    my $tmp = File::Spec->catdir($root, 't', 'tmp_mb179_scripts');
    make_path($tmp);

    my $script = File::Spec->catfile($tmp, 'bridge_ok.pl');
    open my $fh, '>', $script
        or do { $assert->(0, "cannot write bridge script: $!"); return; };
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
            text => 'bridge:' . ($payload->{data}{command} || '')
        },
        {
            type => 'log',
            level => 'info',
            text => 'bridge dry-run ok'
        }
    ]
});
EOS
    close $fh;

    my $bot = Mediabot->new({
        conf => BridgeConf->new(
            'plugins.ScriptDryRun.SCRIPT' => 'bridge_ok.pl',
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

    $assert->($entry && $entry->{module} eq 'Mediabot::Plugin::ScriptDryRun',
        'PluginManager loads ScriptDryRun plugin explicitly');
    $assert->($bot->plugin_manager->is_registered('Mediabot::Plugin::ScriptDryRun'),
        'ScriptDryRun plugin is registered');
    $assert->($bot->events->listener_count('public_command_observed') == 1,
        'ScriptDryRun plugin registered one public_command_observed listener');

    my $plugin = $bot->plugin_manager->object_for('Mediabot::Plugin::ScriptDryRun');
    $assert->($plugin && ref($plugin) eq 'Mediabot::Plugin::ScriptDryRun',
        'ScriptDryRun plugin object is stored by PluginManager');
    $assert->($plugin->script_path eq 'bridge_ok.pl',
        'ScriptDryRun plugin reads configured script path');

    my $ctx = {
        channel => '#teuk',
        nick    => 'Te[u]K',
        command => 'demo',
        args    => [ 'a', 'b' ],
    };

    my $ran = $bot->events->emit_report('public_command_observed', $ctx);

    $assert->($ran->{ran} == 1,
        'EventBus ran ScriptDryRun listener');
    $assert->($plugin->observed_public == 1,
        'ScriptDryRun observed one public command');

    my $result = $plugin->last_result;
    $assert->($result && $result->{dry_run} && $result->{ok},
        'ScriptDryRun stored OK dry-run pipeline result');
    $assert->($result->{script_result}{ok},
        'ScriptDryRun subprocess result is OK');
    $assert->($result->{action_plan}{ok},
        'ScriptDryRun action plan is OK');
    $assert->(@{ $result->{action_plan}{planned} } == 2,
        'ScriptDryRun planned two actions');
    $assert->($result->{action_plan}{planned}[0]{type} eq 'reply',
        'ScriptDryRun planned reply action');
    $assert->($result->{action_plan}{planned}[0]{target} eq '#teuk',
        'ScriptDryRun reply target defaults from EventBus context channel');
    $assert->($result->{action_plan}{planned}[0]{text} eq 'bridge:demo',
        'ScriptDryRun reply text comes from external script');

    my $bot_skip = Mediabot->new({ conf => BridgeConf->new() });
    $bot_skip->{script_runner} = $bot->{script_runner};
    $bot_skip->{script_action_runner} = $bot->{script_action_runner};
    my $skip_entry = $bot_skip->plugin_manager->load_perl_module('Mediabot::Plugin::ScriptDryRun');
    my $skip_plugin = $bot_skip->plugin_manager->object_for('Mediabot::Plugin::ScriptDryRun');

    $bot_skip->events->emit_report('public_command_observed', $ctx);

    $assert->($skip_plugin->observed_public == 1 && $skip_plugin->skipped_public == 1,
        'ScriptDryRun skips safely when no script is configured');
    $assert->($skip_plugin->last_error =~ /not allowed by ScriptDryRun filter/,
        'ScriptDryRun rejects an unconfigured command before script resolution');

    my $plugin_file = File::Spec->catfile($root, 'Mediabot', 'Plugin', 'ScriptDryRun.pm');
    open my $pfh, '<', $plugin_file
        or do { $assert->(0, "cannot open ScriptDryRun.pm: $!"); return; };
    my $plugin_src = do { local $/; <$pfh> };
    close $pfh;

    $assert->(scalar($plugin_src =~ /Trusted in-process bridge from EventBus to external Perl\/Python\/Tcl scripts/),
        'ScriptDryRun source documents the active multilingual bridge');
    $assert->($plugin_src =~ /public_command_observed/,
        'ScriptDryRun listens to public_command_observed');
    $assert->(scalar($plugin_src =~ /run_script_actions_dry/),
        'ScriptDryRun keeps the dry-run script pipeline');
    $assert->(scalar($plugin_src =~ /apply_actions/),
        'ScriptDryRun also wires explicitly gated apply mode');
    $assert->($plugin_src !~ /send_privmsg|send_notice|send_message|dbh->|prepare\(|INSERT|UPDATE|DELETE/,
        'ScriptDryRun does not send IRC messages or touch DB');
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
