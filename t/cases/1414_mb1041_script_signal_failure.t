use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp qw(tempdir);
use POSIX ();
use Mediabot::ScriptRunner;
use Mediabot::ScriptActionRunner;

{
    package MB1041::IRC;
    sub send_message { push @{$_[0]{messages}}, [@_[1..$#_]]; 1 }
    package MB1041::Log;
    sub log { push @{$_[0]{entries}}, [@_[1..$#_]]; 1 }
}
my @warnings;
local $SIG{__WARN__} = sub { push @warnings, @_ };
my $dir = tempdir(CLEANUP => 1);
my $json = q{{"protocol":"mediabot-script-v1","ok":true,"actions":[{"type":"reply","text":"fixture reply"},{"type":"log","text":"fixture log"},{"type":"store","data":{"fixture":1}}]}};
sub script_1414 {
    my ($name, $ending, $close, $invalid) = @_;
    open my $fh, '>', "$dir/$name.pl" or die $!;
    print {$fh} "use strict; use warnings; use IO::Handle;\n";
    print {$fh} 'my $input = do { local $/; <STDIN> }; STDOUT->autoflush(1);' . "\n";
    print {$fh} 'print q{' . ($invalid ? 'not json' : $json) . '};' . "\n";
    print {$fh} 'print STDERR "fixture stderr\\n";' . "\n";
    print {$fh} "close STDOUT; close STDERR;\n" if $close;
    print {$fh} "$ending\n";
    close $fh or die $!;
}
my $runner = Mediabot::ScriptRunner->new(script_dir => $dir, timeout => 1);
my $context = {event => 'public_command', channel => '#test', target => '#test',
    nick => 'Observer', command => 'fixture', args => []};
sub run_1414 { $runner->run_script($_[0], 'public_command', %$context) }
sub status_1414 {
    my ($r) = @_;
    return [$r->{ok} ? 1 : 0, $r->{timeout} ? 1 : 0, $r->{exit_code}, $r->{signal}];
}
sub apply_1414 {
    my ($r) = @_;
    my $irc = bless {messages => []}, 'MB1041::IRC';
    my $log = bless {entries => []}, 'MB1041::Log';
    my $applier = Mediabot::ScriptActionRunner->new(bot => {irc => $irc, logger => $log});
    my $dry = $applier->apply_actions_dry($r, $context);
    my $stores = 0;
    my $applied = $applier->apply_actions($r, $context,
        apply => 1, allow_irc => 1, allow_store => 1,
        store_sink => sub { $stores++; return (1, undef) });
    return [$dry->{ok} ? 1 : 0, scalar(@{$dry->{planned}}),
        $applied->{ok} ? 1 : 0, scalar(@{$applied->{applied}}),
        scalar(@{$irc->{messages}}), scalar(@{$log->{entries}}), $stores];
}
for my $case (['TERM', POSIX::SIGTERM(), 0], ['INT', POSIX::SIGINT(), 1], ['KILL', POSIX::SIGKILL(), 0]) {
    my ($name, $number, $close) = @$case;
    # A real child flushes valid JSON, then terminates itself. No status mock,
    # parent signal, shell invocation or external service is involved.
    script_1414(lc($name), '$SIG{' . $name . '} = "DEFAULT"; kill "' . $name . '", $$; exit 99;', $close, 0);
    my $r = run_1414(lc($name) . '.pl');
    is_deeply(status_1414($r), [0,0,undef,$number],
        "$name termination is failure with its real signal and no fictitious exit code zero");
    is_deeply([$r->{response}{ok} ? 1 : 0, scalar(@{$r->{response}{actions}}), $r->{stdout}, $r->{stderr}],
        [1,3,$json,"fixture stderr\n"],
        "$name preserves the parsed response and captured streams for diagnostics");
    is_deeply(apply_1414($r), [0,0,0,0,0,0,0],
        "$name cannot plan or apply reply, log or storage actions through the real action runner");
    is($r->{error}, "script terminated by signal $number", "$name has a bounded numeric process-failure diagnostic");
}
script_1414('healthy', 'exit 0;', 0, 0);
my $healthy = run_1414('healthy.pl');
is_deeply([status_1414($healthy), apply_1414($healthy)], [[1,0,0,0],[1,3,1,3,1,1,1]],
    'normal exit zero still admits and applies the same valid reply, log and storage actions');
script_1414('nonzero', 'exit 42;', 0, 0);
my $nonzero = run_1414('nonzero.pl');
is_deeply([status_1414($nonzero), apply_1414($nonzero)], [[0,0,42,0],[0,0,0,0,0,0,0]],
    'ordinary nonzero exit remains distinct from a signal and cannot apply its valid JSON actions');
script_1414('invalid', 'exit 0;', 0, 1);
my $invalid = run_1414('invalid.pl');
is_deeply([status_1414($invalid), $invalid->{response}{ok} ? 1 : 0, apply_1414($invalid)],
    [[0,0,0,0],0,[0,0,0,0,0,0,0]],
    'clean process exit still cannot turn an invalid protocol response into success');
script_1414('slow', 'sleep 3; exit 0;', 0, 0);
my $slow = run_1414('slow.pl');
is_deeply(status_1414($slow), [0,1,undef,undef], 'runner-enforced timeout keeps its existing distinct result fields');
is_deeply(apply_1414($slow), [0,0,0,0,0,0,0], 'a valid JSON prefix before timeout still cannot apply any action');
is_deeply(\@warnings, [], 'native signal, normal exit, protocol failure and timeout paths are warning-free');
done_testing;
