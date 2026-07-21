# t/cases/413_mb174_script_runner_foundation.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;
use JSON::PP qw(decode_json);

my $case = sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');
    unshift @INC, $root;

    eval { require Mediabot::ScriptRunner; 1 }
        or do { $assert->(0, "cannot load Mediabot::ScriptRunner: $@"); return; };

    my $runner = Mediabot::ScriptRunner->new(
        script_dir       => 'plugins/scripts',
        timeout          => 3,
        max_stdout_bytes => 4096,
    );

    $assert->(ref($runner) eq 'Mediabot::ScriptRunner',
        'ScriptRunner object can be created');
    $assert->($runner->script_dir eq 'plugins/scripts',
        'ScriptRunner stores script_dir');
    $assert->($runner->timeout == 3,
        'ScriptRunner stores timeout');
    $assert->($runner->max_stdout_bytes == 4096,
        'ScriptRunner stores max_stdout_bytes');

    $assert->($runner->language_for('foo.pl') eq 'perl',
        'language_for detects Perl');
    $assert->($runner->language_for('foo.py') eq 'python',
        'language_for detects Python');
    $assert->($runner->language_for('foo.tcl') eq 'tcl',
        'language_for detects Tcl');
    $assert->(!defined $runner->language_for('foo.sh'),
        'language_for rejects unsupported extension');

    my ($ok, $err, $lang, $full) = $runner->validate_script_path('games/duckhunt.tcl');
    $assert->($ok && $lang eq 'tcl' && $full eq 'plugins/scripts/games/duckhunt.tcl',
        'validate_script_path accepts relative Tcl path under script_dir');

    my ($abs_ok, $abs_err) = $runner->validate_script_path('/tmp/evil.py');
    $assert->(!$abs_ok && $abs_err =~ /absolute/,
        'validate_script_path rejects absolute path');

    my ($dot_ok, $dot_err) = $runner->validate_script_path('../evil.py');
    $assert->(!$dot_ok && $dot_err =~ /parent directory/,
        'validate_script_path rejects parent directory traversal');

    my ($ext_ok, $ext_err) = $runner->validate_script_path('bad.sh');
    $assert->(!$ext_ok && $ext_err =~ /unsupported/,
        'validate_script_path rejects unsupported extension');

    my $payload = $runner->build_event_payload(
        'public_command',
        channel => '#test',
        nick    => 'Te[u]K',
        command => 'demo',
        args    => [ 'a', 'b' ],
    );
    $assert->($payload->{protocol} eq 'mediabot-script-v1' && $payload->{event} eq 'public_command',
        'build_event_payload creates protocol envelope');
    $assert->($payload->{data}{channel} eq '#test' && $payload->{data}{command} eq 'demo',
        'build_event_payload stores event data');

    my $json = $runner->encode_event_payload($payload);
    my $decoded = decode_json($json);
    $assert->($decoded->{protocol} eq 'mediabot-script-v1' && $decoded->{data}{nick} eq 'Te[u]K',
        'encode_event_payload returns valid JSON');

    my $response = $runner->decode_script_response('{"actions":[{"type":"reply","target":"#test","text":"ok"},{"type":"log","level":"info","text":"x"}]}');
    $assert->($response->{ok} && @{$response->{actions}} == 2,
        'decode_script_response accepts valid action list');

    my $bad_json = $runner->decode_script_response('{bad json');
    $assert->(!$bad_json->{ok} && $bad_json->{errors}[0] =~ /invalid JSON/,
        'decode_script_response rejects invalid JSON');

    my $bad_action = $runner->decode_script_response('{"actions":[{"type":"exec","cmd":"rm -rf /"}]}');
    $assert->(!$bad_action->{ok} && $bad_action->{errors}[0] =~ /unsupported type/,
        'decode_script_response rejects unsupported action type');

    my @types = $runner->allowed_action_types;
    $assert->(join(',', @types) eq 'log,notice,reply,timer,topic',
        'allowed_action_types returns safe initial action set');

    my $sr_file = File::Spec->catfile($root, 'Mediabot', 'ScriptRunner.pm');
    open my $sfh, '<', $sr_file
        or do { $assert->(0, "cannot open ScriptRunner.pm: $!"); return; };
    my $sr_src = do { local $/; <$sfh> };
    close $sfh;

    $assert->(scalar($sr_src =~ /External Perl\/Python\/Tcl execution boundary/),
        'ScriptRunner source documents the active multilingual execution boundary');
    $assert->(scalar($sr_src =~ /executes scripts out-of-process without a shell/),
        'ScriptRunner source documents guarded subprocess execution');

    my $mediabot_loaded = eval { require 'Mediabot/Mediabot.pm'; 1 };
    unless ($mediabot_loaded) {
        if ($@ =~ /Can't locate (?:DBI|IO::Async|Net::Async|Future)\b/) {
            $assert->(1, 'Mediabot.pm integration skipped: optional runtime dependency missing');
            return;
        }
        $assert->(0, "cannot load Mediabot/Mediabot.pm: $@");
        return;
    }

    my $bot = Mediabot->new({});
    $assert->($bot->script_runner && ref($bot->script_runner) eq 'Mediabot::ScriptRunner',
        'Mediabot constructor creates ScriptRunner');
    $assert->($bot->scripts == $bot->script_runner,
        'Mediabot->scripts is a short alias to script_runner');

    my $main_file = File::Spec->catfile($root, 'Mediabot', 'Mediabot.pm');
    open my $mfh, '<', $main_file
        or do { $assert->(0, "cannot open Mediabot.pm: $!"); return; };
    my $main_src = do { local $/; <$mfh> };
    close $mfh;

    $assert->($main_src =~ /use Mediabot::ScriptRunner;/,
        'Mediabot.pm loads Mediabot::ScriptRunner');
    $assert->($main_src =~ /Mediabot::ScriptRunner->new\(bot => \$self\)/,
        'Mediabot object initializes ScriptRunner with bot reference');
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
