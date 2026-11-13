use strict;
use warnings;
use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC SOL_SOCKET SO_SNDBUF);
use IO::Async::Loop;
use IO::Async::Stream;
use IO::Handle;
use Errno qw(EPIPE);
use Mediabot::IRC::Transport;
use Scalar::Util qw(weaken);

{
    local $SIG{ALRM} = sub { die "MB1269 transport test timeout\n" };
    alarm 15;
    my $pair = sub {
        my (%args) = @_;
        socketpair(my $client, my $peer, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die $!;
        setsockopt($client, SOL_SOCKET, SO_SNDBUF, pack('i',4096)) or die $!;
        $client->blocking(0);
        my $loop = IO::Async::Loop->really_new;
        my $irc = Mediabot::IRC::Transport->new(handle=>$client, %args);
        $loop->add($irc);
        return ($loop,$irc,$peer);
    };
    my $drain = sub {
        my ($loop,$peer,$expected) = @_;
        my $done=$loop->new_future;
        my @lines;
        my $reader=IO::Async::Stream->new(handle=>$peer,on_read=>sub {
            my ($stream,$buf,$eof)=@_;
            push @lines,$1 while $$buf =~ s/^(.*?)\r\n//;
            $done->done if @lines >= $expected && !$done->is_ready;
            return 0;
        });
        $loop->add($reader);
        $loop->await($done);
        return (\@lines,$reader);
    };
    for my $autoflush (0,1) {
        my ($loop,$irc,$peer)=$pair->(autoflush=>$autoflush);
        my (@f,@order);
        for my $i (1..256) {
            push @f,scalar $irc->do_PRIVMSG(target=>'#test',text=>sprintf('%04d ', $i).('x'x380));
            $f[-1]->on_done(sub { push @order,$i });
        }
        ok(!$f[-1]->is_ready,"autoflush=$autoflush: burst has real pending output");
        my $ping="PING :probe\r\n";
        $irc->on_read(\$ping,0);
        my $mode=$irc->send_message('MODE',undef,'#test','+m');
        my $end=$irc->do_NOTICE(target=>'Test',text=>'end');
        my ($lines,$reader)=$drain->($loop,$peer,259);
        my @data=grep { /^PRIVMSG / } @$lines;
        is(scalar @data,256,"autoflush=$autoflush: no lost or duplicate frames");
        is_deeply([map { /:(\d{4}) /; 0+$1 } @data],[1..256], 'ordinary frame order preserved');
        is_deeply(\@order,[1..256],'per-frame completion order preserved');
        my ($pong)=grep {$lines->[$_] eq 'PONG probe'} 0..$#$lines;
        # Native autoflush may have written several frames before PING arrived.
        ok(defined($pong) && $pong<256,'automatic PONG overtakes pending ordinary traffic');
        is($pong,1,'default transport admits at most one earlier frame') unless $autoflush;
        is($lines->[-2],'MODE #test +m','MODE retains its original ordering');
        like($lines->[-1],qr/^NOTICE Test :?end$/,'NOTICE retains ordering');
        ok($mode->is_done && $end->is_done,'control Futures acknowledge native flushing');
        $irc->close_now; $reader->close_now;
    }
    {
        my ($loop,$irc,$peer)=$pair->();
        my (@events,@f);
        push @f,$irc->write("PRIVMSG #test :one\r\n",on_write=>sub {push @events,'write'},on_flush=>sub {push @events,'flush'});
        push @f,$irc->write("PRIVMSG #test :two\r\n");
        $f[1]->cancel;
        $irc->write("PONG priority\r\n");
        my ($lines,$reader)=$drain->($loop,$peer,3);
        is_deeply($lines,['PRIVMSG #test :one','PONG priority','PRIVMSG #test :two'],'cancelled observer does not silently cancel accepted bytes');
        is_deeply(\@events,['write','flush'],'native write and flush callbacks retained');
        ok($f[0]->is_done && $f[1]->is_cancelled,'Future cancellation state retained');
        $irc->close_now; $reader->close_now;
    }
    {
        my ($loop,$irc,$peer)=$pair->();
        my @errors;
        my $payload = {value=>1};
        my $weak_payload = $payload; weaken($weak_payload);
        my $callback = sub { my ($held)=@_; return sub { $held->{value}++ } }->($payload);
        my @f=map {my $i=$_; scalar $irc->write("PRIVMSG #test :$i\r\n",on_error=>sub {push @errors,$i})} 1..3;
        $irc->write("NOTICE Test :unused\r\n", on_flush=>$callback);
        undef $payload; undef $callback;
        $irc->retire_output;
        ok(!defined($weak_payload),'retirement releases queued callback payloads');
        ok(!(grep {!$_->is_failed} @f),'retirement fails all unsent Futures');
        is_deeply([sort @errors],[1,2,3],'retirement reports each accepted write once');
        $irc->retire_output;
        is(scalar @errors,3,'retirement is idempotent');
        eval {$irc->write("PONG stale\r\n")};like($@,qr/retired/,'retired transport refuses new output');
        for (1..3) {$loop->loop_once(0)}
        is_deeply($irc->{_control_pending},undef,'late pump cannot restore retired work');
        close $peer;
        undef $irc; # Native Net::Async::IRC itself retains timer cycles.
    }
    {
        my ($loop,$irc,$peer)=$pair->();
        my $a=$irc->write("PRIVMSG #test :first\r\n");
        my $b=$irc->write("PRIVMSG #test :last\r\n");
        $irc->close_when_empty;
        ok(!$b->is_ready,'graceful close waits for the application queue');
        my ($lines,$reader)=$drain->($loop,$peer,2);
        for (1..5) {$loop->loop_once(0)}
        is_deeply($lines,['PRIVMSG #test :first','PRIVMSG #test :last'],'graceful close flushes all accepted frames');
        ok($a->is_done && $b->is_done,'graceful close preserves acknowledgements');
        ok(!$irc->loop,'graceful close detaches native transport');
        $reader->close_now;
    }
    {
        my ($loop,$irc,$peer)=$pair->();
        $irc->write("PRIVMSG #test :part");
        $irc->write("ial\r\n");
        $irc->write("PONG later\r\n");
        my ($lines,$reader)=$drain->($loop,$peer,2);
        is_deeply($lines,['PRIVMSG #test :partial','PONG later'],'opaque raw writes are barriers, never split by priority output');
        $irc->close_now; $reader->close_now;
    }
    {
        my ($loop,$irc,$peer)=$pair->();
        my $a=$irc->write("PRIVMSG #test :first\r\n");
        my $b=$irc->write("PRIVMSG #test :second\r\n");
        $a->on_done(sub {$irc->write("PONG nested\r\n")});
        my ($lines,$reader)=$drain->($loop,$peer,3);
        is_deeply($lines,['PRIVMSG #test :first','PONG nested','PRIVMSG #test :second'],'reentrant completion cannot burst or reorder ordinary work');
        ok($b->is_done,'reentrant completion preserves successor acknowledgement');
        $irc->close_now; $reader->close_now;
    }
    {
        my ($loop,$irc,$peer)=$pair->(writer=>sub { $!=EPIPE; return undef });
        my $a=$irc->write("PRIVMSG #test :fail\r\n");
        my $b=$irc->write("NOTICE Test :pending\r\n");
        for (1..10) {last if $b->is_ready; $loop->loop_once(0.01)}
        ok($a->is_failed && $b->is_failed,'native write failure fails active and pending acknowledgements');
        ok(!$irc->loop,'native write failure closes transport');
        close $peer;
    }
    {
        my ($loop,$irc,$peer)=$pair->();
        my $a=$irc->write("PRIVMSG #test :active\r\n",on_error=>sub {die "active callback failure\n"});
        my $b=$irc->write("NOTICE Test :pending\r\n",on_error=>sub {die "pending callback failure\n"});
        $a->on_fail(sub {die "active observer callback failure\n"});
        $b->on_fail(sub {die "pending observer callback failure\n"});
        eval {$irc->close_now};
        like($@,qr/callback failure/,'close preserves a consumer exception');
        ok($a->is_failed && $b->is_failed,'consumer exceptions cannot strand acknowledgements');
        ok(!$irc->loop,'consumer exceptions do not prevent native closure');
        close $peer;
    }
    SKIP: {
        skip 'native Mediabot integration runs in case 1313', 3 unless defined &Mediabot::setIrc;
        my ($loop,$old,$peer)=$pair->();
        my $a=$old->write("PRIVMSG #test :old1\r\n");
        my $b=$old->write("PRIVMSG #test :old2\r\n");
        my ($new_loop,$new,$new_peer)=$pair->();
        my $bot=bless {irc=>$old}, 'Mediabot';
        $bot->setIrc($new);
        is($bot->{irc},$new,'setIrc publishes successor');
        ok($a->is_failed && $b->is_failed,'setIrc retires old active and pending writes');
        ok(!$old->loop,'setIrc closes old transport');
        $new->close_now; close $peer; close $new_peer;
    }
    alarm 0;
}
1;
