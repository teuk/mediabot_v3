use strict;
use warnings;
use utf8;
use Encode qw(encode);
use Scalar::Util qw(refaddr);
use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use IO::Async::Loop;
use IO::Async::Stream;
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
use Mediabot::Mediabot ();
use Mediabot::IRC::Transport;
use Mediabot::IRC::Timer ();
use MB881OutputFixture;

# No address, DNS, configuration file or connect() call: both ends are local
# anonymous Unix sockets. This is a transport boundary, not an OS egress sandbox.
{
    local $SIG{ALRM} = sub {die "Local IRC qualification timed out\n"};
    alarm 15;
    no warnings qw(redefine once);
    local *Net::Async::IRC::connect = sub {die "External IRC connect forbidden in local qualification\n"};
    local *IO::Async::Loop::connect = sub {die "IP connect forbidden in local qualification\n"};
    local *IO::Async::Loop::resolve = sub {die "DNS forbidden in local qualification\n"};
    my $loop = IO::Async::Loop->really_new;
    my $bot = MB881OutputFixture::new_bot();
    bless $bot, 'Mediabot';
    $bot->{loop} = $loop;
    $bot->{command_registry} = Mediabot::CommandRegistry->new;
    $bot->_register_builtin_command_catalogue;
    my $received = 0;
    my $pump = sub {
        my ($until) = @_;
        my $end = clock_gettime(CLOCK_MONOTONIC) + 2;
        while (!$until->()) {
            die "Local IRC journey did not complete\n" if clock_gettime(CLOCK_MONOTONIC) >= $end;
            $loop->loop_once(0.01);
        }
    };
    my $pair = sub {
        socketpair(my $client, my $server, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die $!;
        my @wire;
        my $peer = IO::Async::Stream->new(handle=>$server, on_read=>sub {
            my ($stream,$buffer,$eof)=@_;
            push @wire,$1 while $$buffer =~ s/^(.*?)\r\n//;
            return 0;
        });
        my $irc = Mediabot::IRC::Transport->new(handle=>$client, nick=>'qualifier',
            on_message_PRIVMSG=>sub {
                my ($transport,$message,$hints)=@_;
                my $target=$hints->{targets};
                my ($command,@args)=split / +/, Mediabot::Helpers::decode_irc_text($hints->{text});
                die 'Unexpected qualification command' unless $command =~ s/^!//;
                if ($target eq '#qualification') {
                    $bot->mbCommandPublic($message,$target,$hints->{prefix_nick},0,$command,@args);
                } elsif ($target eq 'qualifier') {
                    $bot->mbCommandPrivate($message,$hints->{prefix_nick},$command,@args);
                } else {die 'Unexpected qualification target'}
                ++$received;
            });
        $loop->add($peer); $loop->add($irc);
        return ($irc,$peer,\@wire);
    };
    # Storage, history and admission are controlled seams. Dispatch, built-in
    # handlers, Context, Sender, queue ownership and wire parsing stay native.
    local *Mediabot::checkChanFlood = sub {0};
    local *Mediabot::checkNickFlood = sub {0};
    local *Mediabot::checkCmdCooldown = sub {0};
    my @expiry;
    my $countdown = Mediabot::IRC::Timer->can('countdown');
    local *Mediabot::IRC::Timer::countdown = sub {
        my %args=@_; push @expiry,$args{on_expire}; return $countdown->(%args);
    };
    MB881OutputFixture::with_policy(sub {
        my ($old,$server,$wire)=$pair->();
        $bot->setIrc($old);
        $server->write(":Alice!test\@local PRIVMSG #qualification :!spike\r\n");
        $pump->(sub {@$wire==1});
        is_deeply($wire,['PRIVMSG #qualification https://teuk.org/In_Spike_Memory.jpg'],
            'public IRC frame reaches native registry, built-in, Context and Sender');
        $server->write(encode('UTF-8', ":Alice!test\@local PRIVMSG qualifier :!echo privé 🪄\r\n"));
        $pump->(sub {@$wire==2});
        is($wire->[1],encode('UTF-8','PRIVMSG Alice :privé 🪄'),
            'private built-in preserves UTF-8 and replies only to originating nick');
        $bot->{policy}{AntiFlood}=1; $bot->{blocked}=1;
        $server->write(":Alice!test\@local PRIVMSG #qualification :!spike\r\n");
        $pump->(sub {$received==3});
        my $queued=$bot->{_flood_outq}{'#qualification'};
        is(scalar @{$queued->{items}},1,'public reply waits in the real deferred queue');
        my $retired_timer=$queued->{timer};
        ok($retired_timer && @expiry==1,'deferred reply owns a native countdown');
        is(scalar @$wire,2,'deferred reply has not reached the old wire');
        my ($fresh,$new_server,$new_wire)=$pair->();
        $bot->setIrc($fresh);
        ok($old->{_control_retired},'replacement retires the old native transport');
        ok(!$bot->{_flood_outq},'replacement removes old deferred queue ownership');
        $bot->{blocked}=0;
        $expiry[0]->(); # Late callback must not deliver into the successor.
        $new_server->write(":Alice!test\@local PRIVMSG qualifier :!echo fresh-reply\r\nPING :barrier\r\n");
        $pump->(sub {grep {$_ eq 'PONG barrier'} @$new_wire});
        # PONG may overtake ordinary output; await the fresh response as well.
        $pump->(sub {grep {/fresh-reply/} @$new_wire});
        is_deeply([grep {/^PRIVMSG /} @$new_wire],['PRIVMSG Alice fresh-reply'],
            'late old callback cannot inject a stale public reply into the successor');
        is(scalar @$wire,2,'old peer receives no deferred reply after replacement');
        is(scalar(grep {refaddr($_)==refaddr($retired_timer)} $loop->notifiers),0,
            'reconnection releases the retired deferred countdown');
        $old->close_now; $fresh->close_now; $server->close_now; $new_server->close_now;
    });
    alarm 0;
}
1;
