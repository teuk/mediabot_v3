use strict;
use warnings;
use utf8;
use lib '.', 't/lib';
use Test::More;
use File::Temp qw(tempdir);
use Mediabot::Log;

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
        ok($ok, "failure $n: automatic reopen error does not escape log()");
        like(mb854_read("$path.held"), qr/rotation failure $n privé 🧭/,
            "failure $n: current record reaches the still-open descriptor");
        is(scalar @console, $n + 1, "failure $n: partyline console receives the current record once");
    }
    is(scalar @warnings, 1, 'one bounded diagnostic is emitted for the failed rotation streak');
    like(join('', @warnings), qr/logfile rotation failed/i, 'diagnostic identifies rotation failure');
    unlike(join('', @warnings), qr/\Q$dir\E|privé|🧭/, 'diagnostic contains no path or log message');
    ok(defined fileno($old_handle), 'automatic failure preserves the live descriptor');
    my $ok = eval {$logger->reopen_logfile; 1};
    ok(!$ok && $@ =~ /Cannot open logfile/, 'explicit reopen failure remains explicit');
    $logger->log(5, 'filtered debug record');
    is(scalar @console, 3, 'debug filtering remains effective during failed rotation');
    is(scalar @warnings, 1, 'filtered record cannot produce another rotation diagnostic');

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
done_testing;
