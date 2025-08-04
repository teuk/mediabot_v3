#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
binmode STDOUT, ":utf8";

use IO::Async::Loop;
use Net::Async::IRC;
use Future::Utils qw(repeat);
use POSIX qw(strftime);

# Logging
open my $log, '>:utf8', 'test_log.txt' or die "Cannot open log: $!";
select STDOUT; $| = 1;
*STDOUT = *$log;

sub timestamp {
    return strftime("[%Y-%m-%d %H:%M:%S] ", localtime);
}

# IRC config
my $server   = 'teuk.org';
my $port     = 6667;
my $channel  = '#test';
my $nick     = 'mb1';
my $delay    = 2.0;

my @commands = qw(
    nick addtimer remtimer timers msg say act cstat status adduser deluser users
    userinfo addhost addchan chanset purge part join add del modinfo op deop invite voice
    devoice kick topic showcommands chaninfo chanlist whoami auth verify access addcmd
    remcmd modcmd mvcmd chowncmd showcmd chanstatlines whotalk whotalks countcmd topcmd
    popcmd searchcmd lastcmd owncmd holdcmd addcatcmd chcatcmd topsay checkhostchan
    checkhost checknick greet nicklist rnick birthdate colors seen date weather meteo
    addbadword rembadword ignores ignore unignore yt song listeners nextsong wordstat
    addresponder delresponder update lastcom q Q moduser antifloodset leet rehash play
    rplay queue next mp3 exec qlog hailo_ignore hailo_unignore hailo_status hailo_chatter
    whereis birthday f xlogin yomomma spike resolve tmdb tmdblangset debug version help
);

my $loop = IO::Async::Loop->new;
my $irc  = Net::Async::IRC->new();

$irc->configure(
    nick     => $nick,
    user     => $nick,
    realname => 'Automated Command Tester',

    # RAW handler (full message structure)
    on_message => sub {
        my ( $self, $message ) = @_;
        my $cmd    = $message->{command} // '';
        my $prefix = $message->{prefix}  // '';
        my $params = join ' ', @{ $message->{params} // [] };

        print timestamp() . "[IRC RAW] <$prefix> [$cmd] $params\n";

        # Connection complete
        if ( $cmd eq '001' ) {
            print timestamp() . "✅ Welcome received. Joining $channel...\n";
            $irc->send_message( 'JOIN', { channel => $channel } );
        }

        # JOIN by self: begin test sequence
        if ( $cmd eq 'JOIN' && $prefix =~ /^$nick!/ ) {
            print timestamp() . "🔗 JOIN confirmed. Starting test sequence...\n";

            repeat(
                sub {
                    my $cmd = shift @commands;
                    return Future->done unless defined $cmd;

                    my $line = "!$cmd testarg1 testarg2";
                    print timestamp() . "→ Sending: $line\n";

                    $irc->send_message( 'PRIVMSG', {
                        target => $channel,
                        text   => $line
                    });

                    return $loop->delay_future( after => $delay );
                },
                while => sub { @commands }
            )->on_done(sub {
                print timestamp() . "✅ All commands sent.\n";
            })->retain;
        }
    },

    # Only plain messages (text in channels/PMs)
    on_message_text => sub {
        my ( $self, $text, $hints ) = @_;
        my $prefix = $hints->{prefix} // '';
        my $target = $hints->{params}[0] // '';

        print timestamp() . "[IRC TEXT] <$prefix> [$target] $text\n";
    },

    # Error handler
    on_error => sub {
        my ( $self, $err ) = @_;
        print timestamp() . "⚠️ ERROR: $err\n";
    },
);

# Launch
print timestamp() . "⏳ Connecting to $server:$port as $nick...\n";
$loop->add($irc);

$irc->connect(
    host    => $server,
    service => $port,
)->then(sub {
    print timestamp() . "🔌 Connected. Awaiting welcome...\n";
    Future->done;
})->get;

print timestamp() . "🏁 Setup complete. Running...\n";
$loop->run;
