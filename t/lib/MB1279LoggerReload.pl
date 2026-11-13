use strict;
use warnings;
use Mediabot::Mediabot;
use Mediabot::Conf;
use Scalar::Util qw(refaddr);

# Execute inside the existing isolated logger case, with native file handles,
# core and logger. Only constructor failures are injected; no service is started.
{
    my $tmp = File::Temp::tempdir(CLEANUP => 1);
    my $original_new = Mediabot::Log->can('new');
    for my $mode (qw(open constructor false success)) {
        my $oldpath = "$tmp/$mode.old";
        my $newpath = $mode eq 'open' ? "$tmp/missing/log" : "$tmp/$mode.new";
        open my $raw, '>>', $oldpath or die $!;
        $raw->autoflush(1);
        my $log = Mediabot::Log->new(logfile => $oldpath, debug_level => 2);
        my @hooks;
        $log->add_console_hook('operator', 2, sub { push @hooks, $_[0] });
        my $bot = bless {
            LOG => $raw, logger => $log,
            conf => Mediabot::Conf->new({
                'main.MAIN_LOG_FILE' => $newpath,
                'main.MAIN_PROG_DEBUG' => 2,
            }),
        }, 'Mediabot';
        my ($result, $error);
        {
            no warnings 'redefine';
            local *Mediabot::Log::new = sub {
                die "injected logger constructor failure\n" if $mode eq 'constructor';
                return if $mode eq 'false';
                return $original_new->(@_);
            };
            $result = eval { $bot->reload_logger_from_config() };
            $error = $@;
        }
        Test::More::is($error, '', "$mode: reload does not throw");
        if ($mode ne 'success') {
            Test::More::ok(!$result, "$mode: failure is reported");
            Test::More::is(refaddr($bot->{LOG}), refaddr($raw), "$mode: raw handle owner preserved");
            Test::More::is(refaddr($bot->{logger}), refaddr($log), "$mode: logger owner preserved");
            Test::More::ok(defined fileno($raw), "$mode: original raw descriptor remains open");
            my $written;
            { local $SIG{__WARN__} = sub {}; $written = print {$raw} "raw-after-$mode\n"; }
            Test::More::ok($written, "$mode: original raw descriptor remains writable");
            $log->log(0, "object-after-$mode");
            Test::More::like(contents($oldpath), qr/raw-after-$mode/, "$mode: raw record reaches old file");
            Test::More::like(contents($oldpath), qr/object-after-$mode/, "$mode: object record reaches old file");
            Test::More::is(scalar(grep /object-after-$mode/, @hooks), 1, "$mode: console hook still delivers once");
        } else {
            Test::More::ok($result, 'success: replacement accepted');
            Test::More::isnt(refaddr($bot->{LOG}), refaddr($raw), 'success: raw owner replaced');
            Test::More::isnt(refaddr($bot->{logger}), refaddr($log), 'success: object owner replaced');
            Test::More::ok(!defined fileno($raw), 'success: old raw descriptor closed');
            print {$bot->{LOG}} "new-raw-record\n" or die $!;
            $bot->{logger}->log(0, 'new-object-record');
            Test::More::like(contents($newpath), qr/new-raw-record/, 'success: raw writes reach new destination');
            Test::More::like(contents($newpath), qr/new-object-record/, 'success: object writes reach new destination');
            Test::More::unlike(contents($oldpath), qr/new-(?:raw|object)-record/, 'success: old file receives neither new record');
            Test::More::is(scalar(grep /new-object-record/, @hooks), 1, 'success: existing console hook retained once');
        }
        close $bot->{LOG} if defined fileno($bot->{LOG});
        close $bot->{logger}{logfilehandle} if $bot->{logger} && $bot->{logger}{logfilehandle};
        close $log->{logfilehandle} if defined fileno($log->{logfilehandle});
    }
}
1;
