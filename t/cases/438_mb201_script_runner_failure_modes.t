#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use File::Spec;
use File::Temp qw(tempdir);
use lib File::Spec->rel2abs(File::Spec->curdir());

use Mediabot::ScriptRunner;
use Mediabot::ScriptActionRunner;

{
    package MB201::FakeIRC;
    sub new { bless { messages => [] }, shift }
    sub send_message {
        my ($self, @args) = @_;
        push @{ $self->{messages} }, \@args;
        return 1;
    }
    sub messages { return $_[0]->{messages}; }
}

{
    package MB201::FakeLogger;
    sub new { bless { entries => [] }, shift }
    sub log {
        my ($self, @args) = @_;
        push @{ $self->{entries} }, \@args;
        return 1;
    }
    sub entries { return $_[0]->{entries}; }
}

my @fail;

sub ok {
    my ($cond, $msg) = @_;
    if ($cond) {
        print "ok - $msg\n";
    }
    else {
        print "not ok - $msg\n";
        push @fail, $msg;
    }
}

sub write_script {
    my ($dir, $name, $body) = @_;
    my $path = File::Spec->catfile($dir, $name);
    open my $fh, '>:encoding(UTF-8)', $path or die "cannot write $path: $!";
    print {$fh} $body;
    close $fh;
    chmod 0644, $path;
    return $path;
}

my $root = File::Spec->rel2abs(File::Spec->curdir());
my $tmp  = tempdir('mb201_scripts_XXXXXX', DIR => File::Spec->catdir($root, 't'), CLEANUP => 1);

write_script($tmp, 'invalid_json.pl', <<'EOS');
use strict;
use warnings;
print "this is not json\n";
EOS

write_script($tmp, 'valid_json_but_exit_42.pl', <<'EOS');
use strict;
use warnings;
print STDERR "intentional failure on stderr\n";
print '{"actions":[{"type":"reply","text":"must not be sent after exit 42"},{"type":"log","text":"must not be logged after exit 42"}]}';
exit 42;
EOS

write_script($tmp, 'unsupported_action.pl', <<'EOS');
use strict;
use warnings;
print '{"actions":[{"type":"dbwrite","text":"must not be accepted"}]}';
EOS

write_script($tmp, 'timeout.pl', <<'EOS');
use strict;
use warnings;
$| = 1;
print '{"actions":[{"type":"reply","text":"late partial output must not be trusted"}]}';
sleep 3;
EOS

write_script($tmp, 'ok_reply.pl', <<'EOS');
use strict;
use warnings;
print '{"actions":[{"type":"reply","text":"healthy path still works"},{"type":"log","level":"info","text":"healthy log still works"}]}';
EOS

my $irc    = MB201::FakeIRC->new;
my $logger = MB201::FakeLogger->new;
my $bot    = bless { irc => $irc, logger => $logger }, 'MB201::FakeBot';

my $runner = Mediabot::ScriptRunner->new(
    bot              => $bot,
    script_dir       => $tmp,
    timeout          => 1,
    max_stdout_bytes => 8192,
);

my $applier = Mediabot::ScriptActionRunner->new(
    bot             => $bot,
    max_text_length => 400,
);

my $context = {
    event   => 'public_command',
    channel => '#mb201',
    target  => '#mb201',
    nick    => 'Te[u]K',
    command => 'mb201',
    args    => [],
};

my ($abs_ok, $abs_err) = $runner->validate_script_path('/tmp/evil.pl');
ok(!$abs_ok && $abs_err =~ /absolute/, 'ScriptRunner rejects absolute script paths');

my ($dot_ok, $dot_err) = $runner->validate_script_path('../evil.pl');
ok(!$dot_ok && $dot_err =~ /parent directory/, 'ScriptRunner rejects parent directory traversal');

my ($back_ok, $back_err) = $runner->validate_script_path('bad\\path.pl');
ok(!$back_ok && $back_err =~ /backslash/, 'ScriptRunner rejects backslash paths');

my ($ext_ok, $ext_err) = $runner->validate_script_path('evil.sh');
ok(!$ext_ok && $ext_err =~ /unsupported script extension/, 'ScriptRunner rejects unsupported script extensions');

my $path_result = $runner->run_script('../evil.pl', 'public_command', %$context);
ok(ref($path_result) eq 'HASH' && !$path_result->{ok}, 'invalid path returns a structured failed plan');
ok(($path_result->{error} || '') =~ /parent directory/, 'invalid path preserves the validation reason');

my $invalid = $runner->run_script('invalid_json.pl', 'public_command', %$context);
ok(ref($invalid) eq 'HASH', 'invalid JSON returns a structured script result');
ok(!$invalid->{ok}, 'invalid JSON script_result is not ok');
ok(!$invalid->{timeout}, 'invalid JSON does not look like a timeout');
ok(($invalid->{exit_code} // -1) == 0, 'invalid JSON script exits cleanly but still fails protocol');
ok(ref($invalid->{response}) eq 'HASH' && !$invalid->{response}{ok}, 'invalid JSON response is marked failed');
ok(join(' ', @{ $invalid->{response}{errors} || [] }) =~ /invalid JSON response/, 'invalid JSON error is explicit');

my $invalid_plan = $applier->apply_actions($invalid, $context, apply => 1, allow_irc => 1);
ok(!$invalid_plan->{ok}, 'invalid JSON is rejected before action application');
ok(!$invalid_plan->{applied_ok}, 'invalid JSON cannot be fully applied');
ok(ref($invalid_plan->{applied}) eq 'ARRAY' && @{ $invalid_plan->{applied} } == 0, 'invalid JSON applies no actions');

my $exit42 = $runner->run_script('valid_json_but_exit_42.pl', 'public_command', %$context);
ok(ref($exit42) eq 'HASH', 'non-zero exit returns a structured script result');
ok(!$exit42->{ok}, 'non-zero exit script_result is not ok');
ok(($exit42->{exit_code} // -1) == 42, 'non-zero exit preserves exit code');
ok(($exit42->{stderr} || '') =~ /intentional failure/, 'non-zero exit preserves stderr');
ok(ref($exit42->{response}{actions}) eq 'ARRAY' && @{ $exit42->{response}{actions} } == 2, 'non-zero exit may decode actions but they remain untrusted');

my $exit42_plan = $applier->apply_actions($exit42, $context, apply => 1, allow_irc => 1);
ok(!$exit42_plan->{ok}, 'non-zero exit is rejected before action application');
ok(ref($exit42_plan->{planned}) eq 'ARRAY' && @{ $exit42_plan->{planned} } == 0, 'non-zero exit plans zero actions despite decoded output');
ok(ref($exit42_plan->{applied}) eq 'ARRAY' && @{ $exit42_plan->{applied} } == 0, 'non-zero exit applies zero actions');

my $unsupported = $runner->run_script('unsupported_action.pl', 'public_command', %$context);
ok(ref($unsupported) eq 'HASH' && !$unsupported->{ok}, 'unsupported action type makes script_result fail');
ok(ref($unsupported->{response}{actions}) eq 'ARRAY' && @{ $unsupported->{response}{actions} } == 0, 'unsupported action is removed from decoded actions');
ok(join(' ', @{ $unsupported->{response}{errors} || [] }) =~ /unsupported type 'dbwrite'/, 'unsupported action error names rejected type');

my $unsupported_plan = $applier->apply_actions($unsupported, $context, apply => 1, allow_irc => 1);
ok(!$unsupported_plan->{ok}, 'unsupported action response is rejected before application');
ok(ref($unsupported_plan->{applied}) eq 'ARRAY' && @{ $unsupported_plan->{applied} } == 0, 'unsupported action applies no actions');

my $timeout = $runner->run_script('timeout.pl', 'public_command', %$context);
ok(ref($timeout) eq 'HASH', 'timeout returns a structured script result');
ok(!$timeout->{ok}, 'timeout script_result is not ok');
ok($timeout->{timeout}, 'timeout flag is set');
ok(ref($timeout->{response}) eq 'HASH' && !$timeout->{response}{ok}, 'timeout response is failed');
ok(join(' ', @{ $timeout->{response}{errors} || [] }) =~ /script timed out/, 'timeout error is explicit');

my $timeout_plan = $applier->apply_actions($timeout, $context, apply => 1, allow_irc => 1);
ok(!$timeout_plan->{ok}, 'timeout is rejected before action application');
ok(ref($timeout_plan->{planned}) eq 'ARRAY' && @{ $timeout_plan->{planned} } == 0, 'timeout plans zero actions even with partial stdout');
ok(ref($timeout_plan->{applied}) eq 'ARRAY' && @{ $timeout_plan->{applied} } == 0, 'timeout applies zero actions');

ok(@{ $irc->messages } == 0, 'all failed script scenarios sent no IRC messages');
ok(@{ $logger->entries } == 0, 'all failed script scenarios applied no log actions');

my $healthy = $runner->run_script('ok_reply.pl', 'public_command', %$context);
ok(ref($healthy) eq 'HASH' && $healthy->{ok}, 'healthy script still succeeds after failure checks');

my $healthy_plan = $applier->apply_actions($healthy, $context, apply => 1, allow_irc => 1);
ok($healthy_plan->{ok}, 'healthy script action plan is valid');
ok($healthy_plan->{applied_ok}, 'healthy script action plan applies successfully');
ok(@{ $irc->messages } == 1, 'healthy script sends one IRC message');
ok($irc->messages->[0][0] eq 'PRIVMSG' && $irc->messages->[0][2] eq '#mb201' && $irc->messages->[0][3] eq 'healthy path still works',
   'healthy reply uses expected argv-style IRC payload');
ok(@{ $logger->entries } == 1, 'healthy script applies one log action');

my $sr_file = File::Spec->catfile($root, 'Mediabot', 'ScriptRunner.pm');
open my $srfh, '<:encoding(UTF-8)', $sr_file or die "cannot open $sr_file: $!";
my $sr_src = do { local $/; <$srfh> };
close $srfh;

my $ar_file = File::Spec->catfile($root, 'Mediabot', 'ScriptActionRunner.pm');
open my $arfh, '<:encoding(UTF-8)', $ar_file or die "cannot open $ar_file: $!";
my $ar_src = do { local $/; <$arfh> };
close $arfh;

ok($sr_src =~ /IPC::Open3/ && $sr_src =~ /open3\(/, 'ScriptRunner uses argv-based open3 subprocess execution');
ok($sr_src !~ /system\s*\(|qx\//, 'ScriptRunner does not use shell-oriented system or qx execution');
ok($ar_src =~ /mb199-B1: never plan or apply actions when ScriptRunner itself failed/, 'ScriptActionRunner keeps MB199 failed-result guard');
ok($ar_src =~ /mb200-B1: preserve legacy ScriptActionRunner callers/, 'ScriptActionRunner keeps MB200 legacy compatibility guard');

if (@fail) {
    print "FAILED: @fail\n";
    exit 1;
}

exit 0;
