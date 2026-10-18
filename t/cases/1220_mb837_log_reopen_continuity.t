use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use IO::Handle;
use Mediabot::Log;

sub contents {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die $!;
    local $/;
    return <$fh> // '';
}
my $dir = tempdir(CLEANUP => 1);
my $path = "$dir/bot.log";
my $stdout = '';
open my $capture, '>', \$stdout or die $!;
local *STDOUT = $capture;
my $logger = Mediabot::Log->new(logfile => $path, debug_level => 2, maxsize => 1_000_000);
my @console;
$logger->add_console_hook('operator', 2, sub { push @console, $_[0] });
$logger->log(0, 'before reopen');
like(contents($path), qr/before reopen/, 'initial file accepts log records');

# Simulate an unavailable destination without relying on Unix permissions/root.
# The active file remains available by descriptor under its rotated name.
rename($path, "$path.previous") or die $!;
mkdir($path) or die $!;
my @warnings;
{
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    for my $attempt (1..2) {
        my $ok = eval { $logger->reopen_logfile; 1 };
        ok(!$ok, "failed reopen is reported (attempt $attempt)");
        like($@, qr/Cannot open logfile/, 'existing reopen error remains explicit');
        ok(defined(fileno($logger->{logfilehandle})), 'failed candidate leaves the active descriptor open');
        $logger->log(0, "after failed reopen $attempt");
        like(contents("$path.previous"), qr/after failed reopen $attempt/,
            'active file still receives messages after failure');
    }
}
is_deeply(\@warnings, [], 'logging after rejected reopen produces no closed-handle warnings');
is(scalar @console, 3, 'partyline hooks receive each log record once');
like($stdout, qr/after failed reopen 2/, 'standard output logging continues');

rmdir($path) or die $!;
my $old = $logger->{logfilehandle};
ok(eval { $logger->reopen_logfile; 1 }, 'destination recovery permits a successful reopen');
ok(!defined(fileno($old)), 'successful replacement closes the old descriptor');
$logger->log(0, 'after recovery');
like(contents($path), qr/after recovery/, 'new file receives messages after recovery');
unlike(contents("$path.previous"), qr/after recovery/, 'recovered file does not leak new records into old file');

# Existing automatic size rotation must still put its boundary record into
# the new base file, rather than the archive.
$logger->{maxsize} = 1;
$logger->{_write_count} = 99;
$logger->log(0, 'automatic rotation boundary');
like(contents("$path.1"), qr/after recovery/, 'automatic rotation archives previous content');
like(contents($path), qr/automatic rotation boundary/, 'rotation writes boundary record into new file');
unlike(contents("$path.1"), qr/automatic rotation boundary/, 'archive receives no boundary duplicate');
is(scalar @console, 5, 'reopen and rotation do not duplicate console delivery');

my $no_file = Mediabot::Log->new;
ok(eval { $no_file->reopen_logfile; $no_file->log(0, 'console only'); 1 }, 'console-only logger still works');
my $bad = eval { Mediabot::Log->new(logfile => $dir); 1 };
ok(!$bad && $@ =~ /Cannot open logfile/, 'initial invalid destination still fails explicitly');
close $logger->{logfilehandle};
done_testing;
