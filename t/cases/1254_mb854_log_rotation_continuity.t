use strict;
use warnings;
use utf8;
use lib '.', 't/lib';
use Test::More;
use File::Temp qw(tempdir);
use Mediabot::Log;
use Encode qw(decode);

sub mb854_read {
    my ($path) = @_;
    return '' unless -f $path;
    open my $fh, '<:encoding(UTF-8)', $path or die $!;
    local $/; return <$fh> // '';
}
my $dir = tempdir(CLEANUP => 1);
my $path = "$dir/bot.log";
my $stdout = '';
open my $capture, '>:encoding(UTF-8)', \$stdout or die $!;
local *STDOUT = $capture;
my $logger = Mediabot::Log->new(logfile => $path, debug_level => 2, maxsize => 1_000_000, max_files => 2);
my @console;
$logger->add_console_hook('operator', 2, sub {push @console, $_[0]});
$logger->log(0, 'before rotation');
my $old_handle = $logger->{logfilehandle};
rename($path, "$path.held") or die $!;
mkdir($path) or die $!; # Deterministic open failure, including under root.
$logger->{maxsize} = 1;
my @warnings;
{
    local $SIG{__WARN__} = sub {push @warnings, @_};
    for my $n (1..2) {
        $logger->{_write_count} = 99;
        my $ok = eval {$logger->log(0, "rotation failure $n privé 🧭"); 1};
        is_deeply([$ok ? 1 : 0,
            mb854_read("$path.held") =~ /rotation failure $n privé 🧭/ ? 1 : 0,
            scalar @console], [1, 1, $n + 1],
            "failure $n: log contains the error, keeps the active file and dispatches once");
    }
    is(scalar @warnings, 1, 'one bounded diagnostic is emitted for the failed rotation streak');
    like(join('', @warnings), qr/logfile rotation failed/i, 'diagnostic identifies rotation failure');
    unlike(join('', @warnings), qr/\Q$dir\E|privé|🧭/, 'diagnostic contains no path or log message');
    ok(defined fileno($old_handle), 'automatic failure preserves the live descriptor');
    my $ok = eval {$logger->reopen_logfile; 1};
    ok(!$ok && $@ =~ /Cannot open logfile/, 'explicit reopen failure remains explicit');
    $logger->log(5, 'filtered debug record');
    is_deeply([scalar @console, scalar @warnings], [3, 1],
        'filtered records neither reach console nor produce another rotation diagnostic');

    rmdir($path) or die $!;
    rename("$path.held", $path) or die $!;
    $logger->{_write_count} = 99;
    ok(eval {$logger->log(0, 'recovered rotation boundary'); 1}, 'ordinary rotation recovers when destination is available');
    ok(!defined fileno($old_handle), 'successful rotation replaces and closes the old descriptor');
    like(mb854_read($path), qr/recovered rotation boundary/, 'recovery boundary is written to the new base file');
    unlike(mb854_read("$path.1"), qr/recovered rotation boundary/, 'recovery boundary is not duplicated in the archive');
    like(mb854_read("$path.1"), qr/rotation failure 2 privé 🧭/, 'archive retains records written during the failure');
    is(scalar @console, 4, 'successful recovery delivers one console record');
    is(scalar @warnings, 1, 'successful rotation emits no failure diagnostic');

    rename($path, "$path.second-held") or die $!;
    mkdir($path) or die $!;
    $logger->{_write_count} = 99;
    ok(eval {$logger->log(0, 'new failure streak'); 1}, 'later independent rotation failure is also contained');
    is(scalar @warnings, 2, 'a successful rotation resets diagnostic suppression for a later failure');
    like(mb854_read("$path.second-held"), qr/new failure streak/, 'new failed boundary still reaches its active file');
    is(scalar @console, 5, 'later failure also retains console delivery');
    rmdir($path) or die $!;
}
unlike(mb854_read("$path.1"), qr/filtered debug record/, 'filtered debug content never reaches archived logs');
my $plain = Mediabot::Log->new(debug_level => 2);
my $plain_runs = 0;
$plain->add_console_hook('operator', 2, sub {$plain_runs++});
ok(eval {$plain->log(0, 'console-only record'); 1}, 'logger without a file still works');
is($plain_runs, 1, 'console-only logger dispatches once');
close $logger->{logfilehandle};

# MB1076: a hook may log through its transport or exception handler. Use the
# actual logger/file/hooks and cap only the faulty baseline's recursion.
{
    my $stdout = '';
    open my $capture, '>:encoding(UTF-8)', \$stdout or die $!;
    $capture->autoflush(1);
    local *STDOUT = $capture;
    my $path = "$dir/reentrant.log";
    my $log = Mediabot::Log->new(logfile => $path, debug_level => 2);
    my (%seen, $calls);
    for my $id (qw(alpha beta)) {
        $log->add_console_hook($id, 2, sub {
            my $line = $_[0]; $line =~ s/^\[[^\]]+\] \[[^\]]+\] //;
            push @{$seen{$id}}, $line;
            die "fixture recursion cap\n" if ++$calls > 12;
            $log->log(0, "nested $id privé 🧭");
        });
    }
    $log->log(0, 'outer');
    my $records = sub {
        return [sort map {s/^\[[^\]]+\] \[[^\]]+\] //; $_} split /\n/, $_[0]];
    };
    my $want = ['nested alpha privé 🧭', 'nested beta privé 🧭', 'outer'];
    is_deeply([\%seen, $records->(decode('UTF-8', $stdout)), $records->(mb854_read($path))],
        [{alpha => ['outer'], beta => ['outer']}, $want, $want],
        'recursive hooks receive only the outer event; all nested UTF-8 records remain once in stdout and file');
    close $log->{logfilehandle};
}
{
    my $stdout = '';
    open my $capture, '>', \$stdout or die $!;
    $capture->autoflush(1);
    local *STDOUT = $capture;
    my $first = Mediabot::Log->new;
    my $second = Mediabot::Log->new;
    my (@first, @second, $calls);
    $first->add_console_hook('first', 0, sub {
        push @first, $_[0];
        die "fixture recursion cap\n" if ++$calls > 12;
        $second->log(0, 'second logger');
    });
    $second->add_console_hook('second', 0, sub {
        push @second, $_[0];
        die "fixture recursion cap\n" if ++$calls > 12;
        $first->log(0, 'return to first');
    });
    $first->log(0, 'first logger');
    is_deeply([scalar @first, scalar @second, scalar(split /\n/, $stdout),
        $first->get_console_hook_level('first'), $second->get_console_hook_level('second')],
        [1, 1, 3, 0, 0],
        'dispatch guard belongs to one logger; a second logger still delivers and cycles back only to file/stdout');
}
{
    my $stdout = '';
    open my $capture, '>', \$stdout or die $!;
    $capture->autoflush(1);
    local *STDOUT = $capture;
    my $log = Mediabot::Log->new(debug_level => 2);
    my (@survivor, $broken_calls, $die_logs);
    my $error = bless {}, 'MB1076::HookError';
    $log->add_console_hook('broken', 2, sub {
        die "fixture recursion cap\n" if ++$broken_calls > 12;
        $log->log(0, 'nested before hook exception');
        die $error;
    });
    $log->add_console_hook('survivor', 0, sub {push @survivor, $_[0]});
    my $ok;
    {
        local $SIG{__DIE__} = sub {
            $log->log(0, 'hook exception diagnostic') unless $die_logs++;
        };
        $ok = eval {$log->log(0, 'first boundary'); 1};
    }
    $log->remove_console_hook('broken');
    $log->log(1, 'console filtered but filed');
    $log->log(0, 'next boundary');
    is_deeply([$ok ? 1 : 0, $broken_calls,
        [map {/ (first boundary|next boundary)\z/ ? $1 : 'unexpected'} @survivor],
        scalar(split /\n/, $stdout), $log->get_console_hook_level('broken'),
        $log->get_console_hook_level('survivor')],
        [1, 1, ['first boundary', 'next boundary'], 5, undef, 0],
        'a hook and its __DIE__ logger cannot recurse or suppress peers; removal, filtering and next dispatch recover');
}
done_testing;
