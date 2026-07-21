# t/cases/416_mb177_script_action_runner_dryrun.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

my $case = sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');
    unshift @INC, $root;

    eval { require Mediabot::ScriptActionRunner; 1 }
        or do { $assert->(0, "cannot load Mediabot::ScriptActionRunner: $@"); return; };

    my $runner = Mediabot::ScriptActionRunner->new(max_text_length => 40);

    $assert->(ref($runner) eq 'Mediabot::ScriptActionRunner',
        'ScriptActionRunner object can be created');
    $assert->($runner->max_text_length == 40,
        'ScriptActionRunner stores max_text_length');
    $assert->(join(',', $runner->allowed_action_types) eq 'log,notice,reply,timer,topic',
        'ScriptActionRunner exposes safe initial action types');

    my $context = {
        channel => '#test',
        nick    => 'Te[u]K',
    };

    my ($ok_reply, $err_reply, $reply) = $runner->validate_action({
        type => 'reply',
        text => 'hello',
    }, $context);

    $assert->($ok_reply && $reply->{target} eq '#test' && $reply->{text} eq 'hello',
        'reply action defaults target from context');

    my ($ok_notice, undef, $notice) = $runner->validate_action({
        type   => 'notice',
        target => 'Te[u]K',
        text   => 'secret',
    }, $context);

    $assert->($ok_notice && $notice->{type} eq 'notice' && $notice->{target} eq 'Te[u]K',
        'notice action validates explicit target');

    my ($ok_log, undef, $log) = $runner->validate_action({
        type  => 'log',
        level => 'WARN',
        text  => 'careful',
    }, $context);

    $assert->($ok_log && $log->{level} eq 'warn',
        'log action normalizes allowed level');

    my ($ok_timer, undef, $timer) = $runner->validate_action({
        type  => 'timer',
        name  => 'demo',
        delay => 30,
    }, $context);

    $assert->($ok_timer && $timer->{delay} == 30,
        'timer action validates bounded delay');

    my ($bad_type_ok, $bad_type_err) = $runner->validate_action({
        type => 'raw_irc',
        text => 'PRIVMSG #x :oops',
    }, $context);

    $assert->(!$bad_type_ok && $bad_type_err =~ /unsupported/,
        'unsupported action type is rejected');

    my ($long_ok, $long_err) = $runner->validate_action({
        type => 'reply',
        text => ('x' x 100),
    }, $context);

    $assert->(!$long_ok && $long_err =~ /too long/,
        'too long reply text is rejected');

    my ($target_ok, $target_err) = $runner->validate_action({
        type => 'reply',
        text => 'hello',
    }, {});

    $assert->(!$target_ok && $target_err =~ /missing target/,
        'reply without target and without context target is rejected');

    my $plan = $runner->plan_actions([
        { type => 'reply', text => 'one' },
        { type => 'log',   text => 'two', level => 'debug' },
    ], $context);

    $assert->($plan->{ok} && @{$plan->{planned}} == 2 && @{$plan->{errors}} == 0,
        'plan_actions accepts valid action list');

    my $bad_plan = $runner->plan_actions([
        { type => 'reply', text => 'ok' },
        { type => 'exec',  cmd  => 'rm -rf /' },
    ], $context);

    $assert->(!$bad_plan->{ok} && @{$bad_plan->{planned}} == 1 && @{$bad_plan->{errors}} == 1,
        'plan_actions keeps valid actions and reports invalid ones');

    my $dry = $runner->apply_actions_dry({
        response => {
            actions => [
                { type => 'reply', target => '#test', text => 'dry' },
            ],
        },
    }, $context);

    $assert->($dry->{dry_run} && $dry->{ok} && $dry->{planned}[0]{text} eq 'dry',
        'apply_actions_dry returns a dry-run plan');

    my $file = File::Spec->catfile($root, 'Mediabot', 'ScriptActionRunner.pm');
    open my $fh, '<', $file
        or do { $assert->(0, "cannot open ScriptActionRunner.pm: $!"); return; };
    my $src = do { local $/; <$fh> };
    close $fh;

    $assert->(scalar($src =~ /Validator, planner and explicitly gated applier/),
        'ScriptActionRunner source documents its active validator/applier role');
    $assert->(scalar($src =~ /apply_actions\(\) can apply log\/reply\/notice actions/),
        'ScriptActionRunner source documents explicitly gated apply mode');
    $assert->($src =~ /allow_irc/,
        'ScriptActionRunner keeps IRC output behind allow_irc gate');
    $assert->($src =~ /send_message/,
        'ScriptActionRunner uses central send_message path for gated IRC output');
    $assert->($src !~ /dbh->|prepare\(|INSERT|UPDATE|DELETE|\bsystem\s*\(|\bqx\s*(?:\/|\(|\{)/,
        'ScriptActionRunner does not touch DB or shell');

    my $mediabot_loaded = eval { require 'Mediabot/Mediabot.pm'; 1 };
    unless ($mediabot_loaded) {
        if ($@ =~ /Can't locate (?:DBI|IO::Async|Net::Async|Future)\b/) {
            $assert->(1, "Mediabot.pm integration skipped: optional runtime dependency missing in sandbox");
            return;
        }
        $assert->(0, "cannot load Mediabot/Mediabot.pm: $@");
        return;
    }

    my $bot = Mediabot->new({});
    $assert->($bot->script_action_runner && ref($bot->script_action_runner) eq 'Mediabot::ScriptActionRunner',
        'Mediabot constructor creates ScriptActionRunner');
    $assert->($bot->script_actions == $bot->script_action_runner,
        'Mediabot->script_actions is a short alias to script_action_runner');

    my $main_file = File::Spec->catfile($root, 'Mediabot', 'Mediabot.pm');
    open my $mfh, '<', $main_file
        or do { $assert->(0, "cannot open Mediabot.pm: $!"); return; };
    my $main_src = do { local $/; <$mfh> };
    close $mfh;

    $assert->($main_src =~ /use Mediabot::ScriptActionRunner;/,
        'Mediabot.pm loads Mediabot::ScriptActionRunner');
    $assert->($main_src =~ /Mediabot::ScriptActionRunner->new\(bot => \$self\)/,
        'Mediabot initializes ScriptActionRunner with bot reference');
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
