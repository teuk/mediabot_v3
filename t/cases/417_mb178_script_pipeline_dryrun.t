# t/cases/417_mb178_script_pipeline_dryrun.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;
use File::Path qw(make_path);
use JSON::PP qw(decode_json encode_json);

my $case = sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');
    unshift @INC, $root;

    eval { require 'Mediabot/Mediabot.pm'; 1 }
        or do { $assert->(0, "cannot load Mediabot/Mediabot.pm: $@"); return; };

    my $tmp = File::Spec->catdir($root, 't', 'tmp_mb178_scripts');
    make_path($tmp);

    my $perl_script = File::Spec->catfile($tmp, 'pipeline_ok.pl');
    open my $pfh, '>', $perl_script
        or do { $assert->(0, "cannot write Perl pipeline script: $!"); return; };
    print {$pfh} <<'EOS';
use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);
my $in = do { local $/; <STDIN> };
my $payload = decode_json($in);
print encode_json({
    actions => [
        { type => 'reply', text => 'Perl saw ' . ($payload->{data}{command} || '') },
        { type => 'log',   level => 'info', text => 'Perl plugin dry-run log' }
    ]
});
EOS
    close $pfh;

    my $python_script = File::Spec->catfile($tmp, 'pipeline_ok.py');
    open my $pyfh, '>', $python_script
        or do { $assert->(0, "cannot write Python pipeline script: $!"); return; };
    print {$pyfh} <<'EOS';
import json
import sys
payload = json.load(sys.stdin)
print(json.dumps({
    "actions": [
        {"type": "notice", "target": payload["data"].get("nick", "unknown"), "text": "Python saw " + payload["event"]}
    ]
}))
EOS
    close $pyfh;

    my $bad_action_script = File::Spec->catfile($tmp, 'pipeline_bad_action.pl');
    open my $bafh, '>', $bad_action_script
        or do { $assert->(0, "cannot write bad action script: $!"); return; };
    print {$bafh} <<'EOS';
use strict;
use warnings;
use JSON::PP qw(encode_json);
print encode_json({
    actions => [
        { type => 'reply', text => 'valid first action' },
        { type => 'reply', text => ('x' x 500) }
    ]
});
EOS
    close $bafh;

    my $bot = Mediabot->new({});
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

    $assert->($bot->can('run_script_actions_dry'),
        'Mediabot exposes run_script_actions_dry');

    my $perl_result = $bot->run_script_actions_dry(
        'pipeline_ok.pl',
        'public_command',
        channel => '#teuk',
        nick    => 'Te[u]K',
        command => 'demo',
        args    => [ 'one', 'two' ],
    );

    $assert->($perl_result->{dry_run} && $perl_result->{ok},
        'Perl script pipeline returns OK dry-run result');
    $assert->($perl_result->{script_result}{ok},
        'Perl script subprocess result is OK');
    $assert->($perl_result->{action_plan}{ok},
        'Perl script action plan is OK');
    $assert->(@{ $perl_result->{action_plan}{planned} } == 2,
        'Perl script action plan has two planned actions');
    $assert->($perl_result->{action_plan}{planned}[0]{type} eq 'reply',
        'Perl script reply action is planned');
    $assert->($perl_result->{action_plan}{planned}[0]{target} eq '#teuk',
        'Perl script reply target defaults from context channel');

    my $python_result = $bot->run_script_actions_dry(
        'pipeline_ok.py',
        'public_command',
        channel => '#teuk',
        nick    => 'Te[u]K',
        command => 'demo',
    );

    $assert->($python_result->{ok} && $python_result->{action_plan}{planned}[0]{type} eq 'notice',
        'Python script pipeline returns planned notice action');
    $assert->($python_result->{action_plan}{planned}[0]{target} eq 'Te[u]K',
        'Python script explicit notice target is preserved');

    my $bad_result = $bot->run_script_actions_dry(
        'pipeline_bad_action.pl',
        'public_command',
        channel => '#teuk',
        nick    => 'Te[u]K',
        command => 'demo',
    );

    $assert->(!$bad_result->{ok},
        'pipeline result is not OK when one action is invalid');
    $assert->($bad_result->{script_result}{ok},
        'bad action pipeline still has successful subprocess result');
    $assert->(!$bad_result->{action_plan}{ok},
        'bad action pipeline fails at ScriptActionRunner layer');
    $assert->(@{ $bad_result->{action_plan}{planned} } == 1 && @{ $bad_result->{action_plan}{errors} } == 1,
        'bad action pipeline keeps valid action and reports invalid action');
    $assert->($bad_result->{action_plan}{errors}[0]{error} =~ /too long/,
        'bad action pipeline reports ScriptActionRunner text length validation error');

    my $unsafe = $bot->run_script_actions_dry(
        '../pipeline_ok.pl',
        'public_command',
        channel => '#teuk',
    );

    $assert->(!$unsafe->{ok} && !$unsafe->{script_result}{ok},
        'unsafe path fails before action planning success');
    $assert->($unsafe->{script_result}{error} =~ /parent directory/,
        'unsafe path error is preserved in script_result');

    my $main_file = File::Spec->catfile($root, 'Mediabot', 'Mediabot.pm');
    open my $mfh, '<', $main_file
        or do { $assert->(0, "cannot open Mediabot.pm: $!"); return; };
    my $main_src = do { local $/; <$mfh> };
    close $mfh;

    $assert->($main_src =~ /mb178-B1: full dry-run pipeline only/,
        'Mediabot source contains mb178 marker');
    $assert->($main_src =~ /script_runner->run_script/,
        'Mediabot pipeline calls ScriptRunner');
    $assert->($main_src =~ /apply_actions_dry/,
        'Mediabot pipeline calls ScriptActionRunner dry-run');
    $assert->($main_src !~ /run_script_actions_dry.*send_privmsg/s,
        'Mediabot dry-run pipeline does not send IRC messages');
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
