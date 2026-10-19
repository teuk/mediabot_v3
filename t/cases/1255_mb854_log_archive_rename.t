use strict;
use warnings;
use lib '.', 't/lib';
use Test::More;
use File::Temp qw(tempdir);
use Mediabot::Log;

sub mb854_archive_read {
    my ($path) = @_;
    return '' unless -f $path;
    open my $fh, '<:encoding(UTF-8)', $path or die $!;
    local $/; return <$fh> // '';
}
sub mb854_archive_write {
    my ($path, $text) = @_;
    open my $fh, '>:encoding(UTF-8)', $path or die $!;
    print {$fh} $text; close $fh or die $!;
}
my $stdout = '';
open my $capture, '>', \$stdout or die $!;
local *STDOUT = $capture;
for my $stage (qw(older_archive base_file)) {
    my $dir = tempdir(CLEANUP => 1);
    my $path = "$dir/bot.log";
    my $logger = Mediabot::Log->new(logfile => $path, debug_level => 2, maxsize => 1_000_000, max_files => 2);
    $logger->log(0, 'current history');
    my $initial = mb854_archive_read($path);
    if ($stage eq 'older_archive') {
        mb854_archive_write("$path.1", "older history\n");
        mkdir("$path.2") or die $!;
    } else {
        mkdir("$path.1") or die $!;
    }
    $logger->{maxsize} = 1; $logger->{_write_count} = 99;
    my $ok = eval {$logger->_maybe_rotate; 1};
    ok(!$ok, "$stage: failed archive/base rename is reported by the rotation operation");
    like($@, qr/Cannot rotate logfile/, "$stage: failure identifies the rename operation");
    is(mb854_archive_read($path), $initial, "$stage: failed rotation does not replace the current history");
    if ($stage eq 'older_archive') {
        is(mb854_archive_read("$path.1"), "older history\n", 'failed older-archive move cannot be followed by overwriting that archive');
    }
    my (@warnings, @console);
    $logger->add_console_hook('operator', 2, sub {push @console, $_[0]});
    {
        local $SIG{__WARN__} = sub {push @warnings, @_};
        $logger->{_write_count} = 99;
        ok(eval {$logger->log(0, 'blocked rename boundary'); 1}, "$stage: log() contains the archive error");
    }
    like(mb854_archive_read($path), qr/blocked rename boundary/, "$stage: record is appended to the current file");
    is(scalar @console, 1, "$stage: archive failure does not suppress console hooks");
    is(scalar @warnings, 1, "$stage: archive failure emits a diagnostic");
    if ($stage eq 'older_archive') {
        is(mb854_archive_read("$path.1"), "older history\n", 'repeated automatic attempt still preserves the blocked archive');
        rmdir("$path.2") or die $!;
    } else {
        rmdir("$path.1") or die $!;
    }
    $logger->{_write_count} = 99;
    ok(eval {$logger->log(0, 'rename recovery boundary'); 1}, "$stage: normal rotation succeeds after filesystem recovery");
    like(mb854_archive_read($path), qr/rename recovery boundary/, "$stage: recovered boundary goes to the new file");
    unlike(mb854_archive_read("$path.1"), qr/rename recovery boundary/, "$stage: archive has no duplicate recovered boundary");
    like(mb854_archive_read("$path.1"), qr/blocked rename boundary/, "$stage: prior live history is archived on recovery");
    if ($stage eq 'older_archive') {
        is(mb854_archive_read("$path.2"), "older history\n", 'recovery moves the preserved older archive into its proper slot');
    }
    is(scalar @console, 2, "$stage: recovery adds exactly one console delivery");
    close $logger->{logfilehandle};
}
done_testing;
