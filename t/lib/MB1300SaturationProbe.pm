package MB1300SaturationProbe;
use strict;
use warnings;
use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use IO::Async::Loop;
use IO::Async::Stream;
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
use Digest::SHA qw(sha256_hex);
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use Mediabot::Mediabot ();
use Mediabot::IRC::Transport;
use Mediabot::IRC::DeferredOutput ();
use MB881OutputFixture;

sub now {clock_gettime(CLOCK_MONOTONIC)}
sub resources {
    my ($loop)=@_;
    my $r={notifiers=>scalar($loop->notifiers)};
    if (opendir(my $dir,"/proc/$$/fd")) {
        $r->{fds}=scalar grep {/\A\d+\z/} readdir($dir); closedir $dir;
    }
    if (open my $fh,'<',"/proc/$$/status") {
        while (<$fh>) {$r->{rss_kib}=0+$1 if /^VmRSS:\s+(\d+)/} close $fh;
    }
    return $r;
}
sub run {
    local $SIG{ALRM}=sub {die "Bounded saturation probe timed out\n"};
    alarm 15;
    no warnings qw(redefine once);
    local *Net::Async::IRC::connect=sub {die 'External IRC forbidden'};
    local *IO::Async::Loop::connect=sub {die 'IP connect forbidden'};
    local *IO::Async::Loop::resolve=sub {die 'DNS forbidden'};
    my $loop=IO::Async::Loop->really_new;
    my $before=resources($loop);
    socketpair(my $client,my $server,AF_UNIX,SOCK_STREAM,PF_UNSPEC) or die $!;
    my (@wire,%arrival);
    my $peer=IO::Async::Stream->new(handle=>$server,on_read=>sub {
        my ($stream,$buffer,$eof)=@_;
        while ($$buffer =~ s/^(.*?)\r\n//) {push @wire,$1; $arrival{$1}=now()}
        return 0;
    });
    my $irc=Mediabot::IRC::Transport->new(handle=>$client,nick=>'qualifier');
    $loop->add($peer); $loop->add($irc);
    my $bot=MB881OutputFixture::new_bot(); bless $bot,'Mediabot';
    $bot->{loop}=$loop; $bot->setIrc($irc); $bot->{policy}{AntiFlood}=1;
    my $pump=sub {
        my ($until)=@_; my $deadline=now()+2;
        while (!$until->()) {die "Saturation wire deadline exceeded\n" if now()>=$deadline; $loop->loop_once(.01)}
    };
    my $report={schema=>1,scope=>'bounded local bursts; manual drain; virtual expiry; not a throughput or endurance claim',
        perl=>"$^V",budgets=>{queue_lines=>30,response_ttl_s=>120,wire_wait_deadline_s=>2},
        workload=>{drain_cycles=>3,attempts_per_cycle=>40,expiry_lines=>30},cycles=>[],resources_before=>$before};
    my ($attempted_total,$accepted_total,$rejected_total,$delivered_total)=(0,0,0,0);
    MB881OutputFixture::with_policy(sub {
        for my $cycle (1..3) {
            $bot->{blocked}=1;
            my ($accepted,$rejected,$peak)=(0,0,0);
            my @expected;
            for my $i (1..40) {
                my $text=sprintf('cycle-%d-line-%02d',$cycle,$i);
                ++$attempted_total;
                my $ok=Mediabot::Helpers::botPrivmsg($bot,'#load',$text);
                if ($ok) {++$accepted;push @expected,"PRIVMSG #load $text"} else {++$rejected}
                my $depth=scalar @{$bot->{_flood_outq}{'#load'}{items}};
                $peak=$depth if $depth>$peak;
            }
            is_deeply([$accepted,$rejected,$peak],[30,10,30],"burst $cycle: bounded admission and exact rejection accounting");
            my $q=$bot->{_flood_outq}{'#load'};
            my $age=now()-($q->{items}[0][3]{expires_at}-120);
            my $start=scalar @wire; my $ping_at=now();
            $peer->write("PING :load-$cycle\r\n");
            $pump->(sub {exists $arrival{"PONG load-$cycle"}});
            my $latency=$arrival{"PONG load-$cycle"}-$ping_at;
            is_deeply([@wire[$start..$#wire]],["PONG load-$cycle"],"burst $cycle: PING is served while ordinary output remains blocked");
            $bot->{blocked}=0;
            Mediabot::Helpers::_drain_flood_queue($bot,'#load') for 1..30;
            $irc->do_NOTICE(target=>'qualifier',text=>"drained-$cycle");
            $pump->(sub {exists $arrival{"NOTICE qualifier drained-$cycle"}});
            is_deeply([@wire[$start..$#wire]],["PONG load-$cycle",@expected,"NOTICE qualifier drained-$cycle"],
                "burst $cycle: accepted lines arrive once in order, rejected lines never arrive");
            ok(!@{$q->{items}} && !$q->{armed} && !$q->{timer} && !$q->{arm},
                "burst $cycle: drain releases every deferred payload and timer");
            is(scalar(keys %{$bot->{_flood_outq}}),1,"burst $cycle: channel queue registry does not grow");
            my $delivered=scalar grep {/\APRIVMSG #load /} @wire[$start..$#wire];
            $accepted_total+=$accepted; $rejected_total+=$rejected; $delivered_total+=$delivered;
            push @{$report->{cycles}}, {cycle=>$cycle,accepted=>$accepted,rejected=>$rejected,
                peak_queue_depth=>$peak,oldest_queue_age_s=>$age,pong_latency_s=>$latency,
                delivered=>$delivered,resources_after_drain=>resources($loop)};
        }
        $bot->{blocked}=1;
        for (1..30) {
            ++$attempted_total;
            if (Mediabot::Helpers::botPrivmsg($bot,'#load',"expire-$_")) {++$accepted_total}
            else {++$rejected_total}
        }
        my $q=$bot->{_flood_outq}{'#load'};
        my $expiry=now()+121;
        my $expired_before=$bot->{metrics}{counts}{mediabot_antiflood_expired_responses_total}//0;
        {
            local *Mediabot::IRC::DeferredOutput::_flood_queue_now=sub {$expiry};
            Mediabot::Helpers::_drain_flood_queue($bot,'#load');
        }
        my $expired=($bot->{metrics}{counts}{mediabot_antiflood_expired_responses_total}//0)-$expired_before;
        is($expired,30,'virtual expiry accounts for all thirty separate responses');
        my $start=scalar @wire;
        $irc->do_NOTICE(target=>'qualifier',text=>'expiry-barrier');
        $pump->(sub {exists $arrival{'NOTICE qualifier expiry-barrier'}});
        is_deeply([@wire[$start..$#wire]],['NOTICE qualifier expiry-barrier'],'expired output never reaches the wire');
        ok(!@{$q->{items}} && !$q->{timer} && !$q->{armed},'expiry releases deferred payloads and timer');
        my $drops=scalar grep {$_->[1] =~ /flood queue full on #load/} @{$bot->{logger}{rows}};
        is($drops,30,'overflow diagnostics reconcile with all rejected lines');
        $delivered_total+=scalar grep {/\APRIVMSG #load /} @wire[$start..$#wire];
        $report->{totals}={attempted=>$attempted_total,accepted=>$accepted_total,
            delivered=>$delivered_total,rejected=>$rejected_total,expired=>$expired,overflow_diagnostics=>$drops};
        $report->{expiry}={clock=>'injected monotonic advance',advance_s=>121,expired_responses=>$expired};
    });
    $bot->setIrc(undef); $peer->close_now;
    $loop->loop_once(0) for 1..3;
    my $after=resources($loop);
    is($after->{notifiers},$before->{notifiers},'cleanup returns notifier ownership to baseline');
    ok(!$bot->{_flood_outq},'cleanup removes the channel queue registry');
    $report->{resources_after_cleanup}=$after;
    my $root=dirname(dirname(dirname(abs_path(__FILE__))));
    for my $path (qw(t/lib/MB1300SaturationProbe.pm t/lib/MB881OutputFixture.pm
        Mediabot/Helpers.pm Mediabot/IRC/Sender.pm Mediabot/IRC/DeferredOutput.pm
        Mediabot/IRC/Transport.pm Mediabot/IRC/Timer.pm)) {
        open my $fh,'<:raw',"$root/$path" or die $!;
        local $/; $report->{source_sha256}{$path}=sha256_hex(<$fh>); close $fh;
    }
    alarm 0;
    return $report;
}
1;

# Native countdown exercise: no manual drain and no injected clock.
sub run_timed {
    my ($cycles)=@_;
    die "timed cycles must be 1..300\n" unless defined($cycles) && $cycles =~ /\A[0-9]+\z/ && $cycles>=1 && $cycles<=300;
    local $SIG{ALRM}=sub {die "Timed recovery probe exceeded its bound\n"};
    alarm(12*$cycles+10);
    no warnings qw(redefine once);
    local *Net::Async::IRC::connect=sub {die 'External IRC forbidden'};
    local *IO::Async::Loop::connect=sub {die 'IP connect forbidden'};
    local *IO::Async::Loop::resolve=sub {die 'DNS forbidden'};
    my $loop=IO::Async::Loop->really_new;
    my $before=resources($loop);
    socketpair(my $client,my $server,AF_UNIX,SOCK_STREAM,PF_UNSPEC) or die $!;
    my (@wire,%arrival);
    my $peer=IO::Async::Stream->new(handle=>$server,on_read=>sub {
        my ($stream,$buffer,$eof)=@_;
        while ($$buffer =~ s/^(.*?)\r\n//) {push @wire,$1;$arrival{$1}=now()}
        return 0;
    });
    my $irc=Mediabot::IRC::Transport->new(handle=>$client,nick=>'qualifier');
    $loop->add($peer);$loop->add($irc);
    my $bot=MB881OutputFixture::new_bot();bless $bot,'Mediabot';
    $bot->{loop}=$loop;$bot->setIrc($irc);$bot->{policy}{AntiFlood}=1;
    my $connected=resources($loop);
    my $pump=sub {
        my ($until,$seconds)=@_;my $deadline=now()+$seconds;
        while (!$until->()) {die "Timed recovery wire deadline exceeded\n" if now()>=$deadline;$loop->loop_once(.01)}
    };
    my $started=now();my @samples;
    MB881OutputFixture::with_policy(sub {
        for my $cycle (1..$cycles) {
            @wire=();%arrival=();
            $bot->{blocked}=1;
            my $queued_at=now();my $accepted=0;
            for my $channel (qw(#busy #other)) {
                $accepted+=!!Mediabot::Helpers::botPrivmsg($bot,$channel,"timed-$cycle-$_") for 1..2;
            }
            is($accepted,4,"timed $cycle: both channels admit two lines");
            my $ping_at=now();$peer->write("PING :timed-$cycle\r\n");
            $pump->(sub {exists $arrival{"PONG timed-$cycle"}},2);
            is_deeply(\@wire,["PONG timed-$cycle"],"timed $cycle: PING crosses queued ordinary traffic");
            $bot->{blocked}=0;
            $pump->(sub {exists($arrival{"PRIVMSG #busy timed-$cycle-2"}) && exists($arrival{"PRIVMSG #other timed-$cycle-2"})},10);
            $irc->do_NOTICE(target=>'qualifier',text=>"timed-barrier-$cycle");
            $pump->(sub {exists $arrival{"NOTICE qualifier timed-barrier-$cycle"}},2);
            for my $channel (qw(#busy #other)) {
                is_deeply([grep {/^PRIVMSG \Q$channel\E /} @wire],
                    [map {"PRIVMSG $channel timed-$cycle-$_"} 1..2],"timed $cycle $channel: native timers deliver once in FIFO order");
                cmp_ok($arrival{"PRIVMSG $channel timed-$cycle-1"}-$queued_at,'>=',1.8,
                    "timed $cycle $channel: initial native delay was not bypassed");
                cmp_ok($arrival{"PRIVMSG $channel timed-$cycle-2"}-$arrival{"PRIVMSG $channel timed-$cycle-1"},'>=',1.8,
                    "timed $cycle $channel: native rearm delay was not bypassed");
                my $q=$bot->{_flood_outq}{$channel};
                ok(!@{$q->{items}} && !$q->{timer} && !$q->{armed} && !$q->{arm},"timed $cycle $channel: timer and payload ownership released");
            }
            is(scalar(@wire),6,"timed $cycle: exact wire accounting");
            my $sample=resources($loop);
            is($sample->{notifiers},$connected->{notifiers},"timed $cycle: notifier count returns to connected baseline");
            if (defined($sample->{fds}) && defined($connected->{fds})) {
                is($sample->{fds},$connected->{fds},"timed $cycle: file descriptor count returns to connected baseline");
            }
            push @samples,{cycle=>$cycle,elapsed_s=>now()-$started,drain_s=>now()-$queued_at,
                pong_latency_s=>$arrival{"PONG timed-$cycle"}-$ping_at,resources=>$sample,
                delivered=>scalar(grep {/^PRIVMSG /} @wire)};
            # Fixture logs are retained by arrays, unlike a streaming sink. Do not
            # mistake their deliberate growth for native queue ownership leakage.
            @{$bot->{logger}{rows}}=();@{$bot->{events}}=();
        }
    });
    $bot->setIrc(undef);$peer->close_now;$loop->loop_once(0) for 1..3;
    my $after=resources($loop);
    is($after->{notifiers},$before->{notifiers},'timed cleanup returns notifiers to initial baseline');
    ok(!$bot->{_flood_outq},'timed cleanup retires both channel queues');
    alarm 0;
    return {scope=>'two-channel native countdown repetition; controlled admission policy; not a production throughput or fairness claim',
        cycles=>$cycles,elapsed_s=>now()-$started,samples=>\@samples,
        resources_before=>$before,resources_connected=>$connected,resources_after_cleanup=>$after,
        budgets=>{drain_wait_s=>10,wire_wait_s=>2,lines_per_channel=>2,channels=>2}};
}

1;
