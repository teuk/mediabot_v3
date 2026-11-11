package MB1238TimerReload;
use strict;
use warnings;
use DBI;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Scalar::Util qw(refaddr);
use Mediabot::DBCommands;
{
    package MB1238TimerReload::Bot;
    our @ISA = ('Mediabot::DBCommands');
    package MB1238TimerReload::IRC;
    sub is_connected { 1 }
    sub write { push @{$_[0]{wire}}, $_[1]; 1 }
    package MB1238TimerReload::Log;
    sub log { $_[0]{hook}->(@_) if $_[0]{hook}; 1 }
}
sub check {
    my ($assert) = @_;
    my $add = IO::Async::Loop->can('add');
    my $remove = IO::Async::Loop->can('remove');
    my $start = IO::Async::Timer::Periodic->can('start');
    my $stop = IO::Async::Timer::Periodic->can('stop');
    my $new = IO::Async::Timer::Periodic->can('new');
    for my $seam (qw(log add_before add_after start_before start_after stop remove rollback_stop rollback_remove)) {
        for my $outcome (qw(success empty db_failure setup_failure)) {
            my $label = "MB1238 $seam/$outcome";
            my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '',
                {RaiseError=>1, PrintError=>0});
            $dbh->do('CREATE TABLE TIMERS (id_timers INTEGER, name TEXT, duration INTEGER, command TEXT)');
            my $rows = sub {
                my ($name) = @_;
                $dbh->do('DELETE FROM TIMERS');
                $dbh->do('INSERT INTO TIMERS VALUES (1, ?, 3600, ?)', undef,
                    $name, "PRIVMSG #offline :$name") if defined $name;
            };
            my $loop = IO::Async::Loop->new;
            # A loop can already own internal signal/child handles. They are
            # not DB timers and must survive this fixture untouched.
            my %existing = map {refaddr($_)=>1} $loop->notifiers;
            my $bot = bless {dbh=>$dbh, loop=>$loop, hTimers=>{},
                irc=>bless({wire=>[]}, 'MB1238TimerReload::IRC')}, 'MB1238TimerReload::Bot';
            $rows->('old');
            $bot->onStartTimers;
            my $old = $bot->{hTimers}{old};
            my (@created, $outer_timer, $cleanup_fired);
            my ($fired, $inner_return) = (0);
            our $nested; local $nested = 0;
            my $trigger = sub {
                return if $fired++;
                local $nested = 1;
                $rows->($outcome eq 'empty' ? undef : 'inner');
                $dbh->do('ALTER TABLE TIMERS RENAME TO unavailable') if $outcome eq 'db_failure';
                $inner_return = $bot->onStartTimers;
                $dbh->do('ALTER TABLE unavailable RENAME TO TIMERS') if $outcome eq 'db_failure';
            };
            $rows->('outer');
            my $outer_return;
            {
                no warnings 'redefine';
                local *IO::Async::Timer::Periodic::new = sub {
                    my $t = $new->(@_); push @created, $t; $outer_timer = $t unless $nested; return $t;
                };
                local *IO::Async::Loop::add = sub {
                    $trigger->() if !$nested && $seam eq 'add_before';
                    my $ret = $add->(@_);
                    die "injected nested setup failure\n" if $nested && $outcome eq 'setup_failure';
                    $trigger->() if !$nested && ($seam eq 'add_after' || $seam =~ /^rollback_/);
                    return $ret;
                };
                local *IO::Async::Timer::Periodic::start = sub {
                    $trigger->() if !$nested && $seam eq 'start_before';
                    my $ret = $start->(@_);
                    $trigger->() if !$nested && $seam eq 'start_after';
                    return $ret;
                };
                my $cleanup_reload = sub {
                    return if $cleanup_fired++;
                    local $nested = 1;
                    $rows->('newest');
                    $bot->onStartTimers;
                };
                local *IO::Async::Timer::Periodic::stop = sub {
                    $cleanup_reload->() if !$nested && $seam eq 'rollback_stop'
                        && $outer_timer && refaddr($_[0])==refaddr($outer_timer);
                    $trigger->() if !$nested && $seam eq 'stop' && refaddr($_[0])==refaddr($old);
                    return $stop->(@_);
                };
                local *IO::Async::Loop::remove = sub {
                    $cleanup_reload->() if !$nested && $seam eq 'rollback_remove'
                        && $outer_timer && refaddr($_[1])==refaddr($outer_timer);
                    $trigger->() if !$nested && $seam eq 'remove' && refaddr($_[1])==refaddr($old);
                    return $remove->(@_);
                };
                # Trigger after the outer SELECT has been consumed, before setup.
                $bot->{logger} = bless {hook=>sub {
                    $trigger->() if !$nested && $seam eq 'log' && $_[2] =~ /active .*set at startup/;
                }}, 'MB1238TimerReload::Log' if $seam eq 'log';
                $outer_return = $bot->onStartTimers;
            }
            delete $bot->{logger};
            my $won = $outcome eq 'success' || $outcome eq 'empty';
            my $expected = $cleanup_fired ? 'newest' : $won ? ($outcome eq 'empty' ? '' : 'inner') : 'outer';
            $assert->($fired && defined $inner_return && $inner_return==($outcome eq 'success'?1:0), "$label nested return");
            $assert->($outer_return==($won?0:1), "$label outer publication return");
            $assert->(join(',',sort keys %{$bot->{hTimers}}) eq $expected, "$label correct published owner");
            my @live = grep {!$existing{refaddr($_)}} $loop->notifiers;
            my @published = values %{$bot->{hTimers}};
            $assert->(@live==@published , "$label notifier count");
            my %live = map {refaddr($_)=>1} @live;
            $assert->(!grep({!$live{refaddr($_)} || !$_->is_running} @published), "$label published timers attached and running");
            my %published = map {refaddr($_)=>1} @published;
            my @retired = grep {!$published{refaddr($_)}} ($old,@created);
            $assert->(!grep({$_->is_running || $_->loop} @retired), "$label losing timers stopped and detached");
            $_->invoke_event('on_tick') for @retired;
            $assert->(!@{$bot->{irc}{wire}}, "$label retained obsolete ticks inert");
            $_->invoke_event('on_tick') for @published;
            $assert->(join('',@{$bot->{irc}{wire}}) eq ($expected eq ''?'':"PRIVMSG #offline :$expected\r\n"), "$label only winning timer writes once");
            $bot->_stop_all_runtime_db_timers;
            # Also clean leaked baseline notifiers so the reproduction is isolated.
            for my $t ($old, @created) { $stop->($t); $remove->($loop,$t) if $t->loop }
            $dbh->disconnect;
        }
    }
}
1;
