package MB936VDMDeliveryFixture;
use strict;
use warnings;
use utf8;
use JSON::PP;
use IO::Async::Loop;
use Time::HiRes qw(time);
use POSIX qw(WNOHANG);
use Mediabot::VDM::Runtime;
use Mediabot::VDM::AsyncFetcher;
use Mediabot::AsyncWorker;
use Mediabot::AI::ConversationRuntimeState;
use Mediabot::Context;
use Mediabot::VDM qw(format_vdm_line);
{
    package MB936::IRC;
    sub is_connected {$_[0]{connected}}
    package MB936::Bot;
    sub getLoop {$_[0]{loop}}
    sub getQuit {$_[0]{quit}}
    package MB936::Logger;
    sub log {push @{$_[0]{entries}},$_[2];1}
}
my $json=JSON::PP->new->canonical->utf8;
my $story="Aujourd'hui, un café après l'école. VDM";
sub check ($$) {die "$_[1]\n" unless $_[0]}
sub state {
    my (@channels)=@_;my $r=Mediabot::AI::ConversationRuntimeState->new;
    $r->mark_connected;$r->mark_joined($_) for @channels;return $r;
}
sub setup {
    my (%a)=@_;my @channels=@{$a{channels}//['#test']};
    my $loop=IO::Async::Loop->really_new;
    my $bot=bless {loop=>$loop,quit=>0,enabled=>{map {$_=>1} @channels},
        channels=>{map {$_=>{}} @channels},sent=>[],notices=>[],
        logger=>bless({entries=>[]},'MB936::Logger')},'MB936::Bot';
    $bot->{irc}=bless {connected=>1,token=>'first'},'MB936::IRC' unless $a{offline};
    $bot->{wit_runtime_state}=state(@channels) unless $a{no_state} || $a{offline};
    my $fetcher=Mediabot::VDM::AsyncFetcher->new(loop=>$loop,timeout=>3,
        fetch_cb=>sub {
            my (%opts)=@_;
            return {ok=>0,error=>'fixture_unavailable'} if $a{failure};
            return {ok=>1,items=>[{id=>$opts{id}//81,story=>$story}]};
        });
    my $runtime=Mediabot::VDM::Runtime->new(bot=>$bot,fetcher=>$fetcher,now_cb=>sub {1000},
        chanset_cb=>sub {$_[0]{enabled}{$_[1]}},
        ($a{offline} ? (connected_cb=>sub {1}) : ()),
        notice_cb=>sub {push @{$_[0]{notices}},[$_[1],$_[2]];1},
        send_cb=>sub {my ($b,$c,$text)=@_;push @{$b->{sent}},[$c,$text,$b->{irc}?$b->{irc}{token}:'offline'];1});
    $bot->{_vdm_runtime}=$runtime;
    return {bot=>$bot,loop=>$loop,fetcher=>$fetcher,runtime=>$runtime,workers=>[]};
}
sub request {
    my ($s,$mode,%a)=@_;my $channel=$a{channel}//'#test';my $rt=$s->{runtime};my $b=$s->{bot};
    my $result;
    if ($mode eq 'manual') {
        my $ctx=Mediabot::Context->new(bot=>$b,channel=>$channel,nick=>'Operator',args=>$a{args}//[]);
        $result=$a{facade} ? Mediabot::VDM::Runtime::mbVdm_ctx($ctx) : $rt->request_manual($ctx);
    }
    else {
        $result=$rt->request_spark(channel=>$channel,
            activity_current_cb=>sub {!$b->{stale_activity}},spark_enabled_cb=>sub {!$b->{spark_disabled}},
            deliver_cb=>sub {my ($item)=@_;push @{$b->{sent}},[$channel,$item->{story},$b->{irc}?$b->{irc}{token}:'offline'];return {action=>'sent'}});
    }
    for my $job (values %{$s->{fetcher}{jobs}}) {
        my $worker=$job->{worker};
        push @{$s->{workers}},$worker if $worker && !grep {$_==$worker} @{$s->{workers}};
    }
    return $result;
}
sub drain {
    my ($s)=@_;my $until=time()+4;
    $s->{loop}->loop_once(0.02) while $s->{fetcher}->inflight && time()<$until;
    check(!$s->{fetcher}->inflight && !$s->{fetcher}->waiter_count,'worker capacity not released');
    for my $w (@{$s->{workers}}) {
        check($w->is_done,'native worker did not complete');
        check(waitpid($w->pid,WNOHANG)==-1,'native worker was not reaped');
    }
}
sub quiet {
    my ($s,$channel)=@_;$channel//='#test';
    check(!@{$s->{bot}{sent}} && !@{$s->{bot}{notices}},'stale delivery emitted story or notice');
    check(!$s->{runtime}->channel_pending($channel),'stale delivery held pending reservation');
    my $row=$s->{runtime}{channel_states}{lc $channel};
    check(!$row || !@{$row->{recent}},'stale delivery consumed repeat history');
}
sub change {
    my ($s,$kind)=@_;my $b=$s->{bot};my $r=$b->{wit_runtime_state};
    if ($kind eq 'reconnect') {
        $b->{irc}{connected}=0;$r->mark_disconnected;
        $b->{irc}{connected}=1;$r->mark_connected;$r->mark_joined('#test');
    }
    elsif ($kind eq 'rejoin') {$r->mark_left('#test');$r->mark_joined('#test')}
    elsif ($kind eq 'transport') {$b->{irc}=bless {connected=>1,token=>'replacement'},'MB936::IRC'}
    elsif ($kind eq 'runtime') {$b->{wit_runtime_state}=state('#test')}
    elsif ($kind eq 'mapping') {$r->update_isupport('CASEMAPPING=rfc1459')}
    elsif ($kind eq 'quit') {$b->{quit}=1}
    elsif ($kind eq 'disconnect') {$b->{irc}{connected}=0;$r->mark_disconnected}
    else {die "unknown change $kind"}
}
sub dispose {
    my ($s)=@_;$s->{fetcher}->cancel('fixture cleanup') if $s->{fetcher}->inflight;
    delete $s->{bot}{_vdm_runtime};
}
sub run_checks {
    my @out;my $group=sub {my ($name,$cb)=@_;my $ok=eval {$cb->();1};
        push @out,{name=>$name,ok=>$ok?1:0,detail=>$ok?'':"$@"}};
    $group->('unchanged contexts preserve manual, numbered, facade and Spark native delivery',sub {
        for my $mode (qw(manual spark)) {
            for my $kind (qw(ordinary numbered facade no_state offline)) {
                next if $mode eq 'spark' && $kind =~ /numbered|facade/;
                my $s=setup($kind eq 'no_state'?(no_state=>1):$kind eq 'offline'?(offline=>1):());
                check(request($s,$mode,($kind eq 'numbered'?(args=>['42']):()),facade=>$kind eq 'facade'),'request rejected');
                check(@{$s->{workers}}==1 && $s->{workers}[0]->pid>0,'real worker not started');
                drain($s);
                check(@{$s->{bot}{sent}}==1 && !@{$s->{bot}{notices}},'ordinary completion changed');
                my $expected=$mode eq 'manual' ? format_vdm_line(id=>$kind eq 'numbered'?42:81,story=>$story) : $story;
                check($s->{bot}{sent}[0][1] eq $expected,'Unicode, badge or requested ID changed');
                check(!$s->{runtime}->channel_pending('#test'),'successful request held reservation');dispose($s);
            }
        }
    });
    $group->('disconnect and reconnect on the same transport revoke the original request',sub {
        for my $mode (qw(manual spark)) {
            my $s=setup();check(request($s,$mode),'request rejected');change($s,'reconnect');
            drain($s);quiet($s);
            check(request($s,$mode),'recovery request rejected');drain($s);
            check(@{$s->{bot}{sent}}==1,'current request could not reuse revoked story');dispose($s);
        }
    });
    $group->('replacement IRC transports and runtime objects cannot inherit old work',sub {
        for my $mode (qw(manual spark)) {
            for my $kind (qw(transport runtime)) {
                my $s=setup();check(request($s,$mode),'request rejected');change($s,$kind);
                drain($s);quiet($s);dispose($s);
            }
            my $s=setup(offline=>1);check(request($s,$mode),'offline request rejected');
            $s->{bot}{irc}=bless {connected=>1,token=>'appeared'},'MB936::IRC';
            drain($s);quiet($s);dispose($s);
        }
    });
    $group->('leave and rejoin or changed IRC casemapping revoke the old generation',sub {
        for my $mode (qw(manual spark)) {
            for my $kind (qw(rejoin mapping)) {
                my $s=setup();check(request($s,$mode),'request rejected');change($s,$kind);
                drain($s);quiet($s);dispose($s);
            }
        }
    });
    $group->('shutdown and stale failed replies stay silent while current errors retain notices',sub {
        for my $mode (qw(manual spark)) {
            my $s=setup();check(request($s,$mode),'request rejected');change($s,'quit');
            drain($s);quiet($s);dispose($s);
            $s=setup(failure=>1);check(request($s,$mode),'failure request rejected');drain($s);
            check(!@{$s->{bot}{sent}} && @{$s->{bot}{notices}}==($mode eq 'manual'?1:0),'current failure diagnostic changed');
            check($s->{bot}{notices}[0][0] eq 'Operator' && $s->{bot}{notices}[0][1] eq 'VDM feed is temporarily unavailable.',
                'current manual failure wording changed') if $mode eq 'manual';dispose($s);
            $s=setup(failure=>1);check(request($s,$mode),'failure request rejected');change($s,'reconnect');
            drain($s);quiet($s);dispose($s);
        }
    });
    $group->('late policy changes and explicit cleanup still revoke pending output',sub {
        for my $mode (qw(manual spark)) {
            for my $kind (qw(disabled unjoined disconnected cleared)) {
                my $s=setup();check(request($s,$mode),'request rejected');
                $s->{bot}{enabled}{'#test'}=0 if $kind eq 'disabled';
                delete $s->{bot}{channels}{'#test'} if $kind eq 'unjoined';
                change($s,'disconnect') if $kind eq 'disconnected';
                $s->{runtime}->clear_channel('#test') if $kind eq 'cleared';
                drain($s);quiet($s);dispose($s);
            }
            if ($mode eq 'spark') {
                for my $kind (qw(stale_activity spark_disabled)) {
                    my $s=setup();check(request($s,$mode),'request rejected');$s->{bot}{$kind}=1;
                    drain($s);quiet($s);dispose($s);
                }
            }
        }
    });
    $group->('coalesced channels retain independent generation and repeat-window ownership',sub {
        for my $mode (qw(manual spark)) {
            my $s=setup(channels=>['#stale','#valid']);
            check(request($s,$mode,channel=>'#stale') && request($s,$mode,channel=>'#valid'),'shared requests rejected');
            check(@{$s->{workers}}==1 && $s->{fetcher}->waiter_count==2,'same feed did not coalesce');
            $s->{bot}{wit_runtime_state}->mark_left('#stale');$s->{bot}{wit_runtime_state}->mark_joined('#stale');
            drain($s);
            check(@{$s->{bot}{sent}}==1 && $s->{bot}{sent}[0][0] eq '#valid','shared worker leaked to stale channel');
            check(!$s->{runtime}->channel_pending('#stale') && !$s->{runtime}->channel_pending('#valid'),'shared reservations not freed');
            check(!@{$s->{runtime}{channel_states}{'#stale'}{recent}} && @{$s->{runtime}{channel_states}{'#valid'}{recent}}==1,'shared repeat history changed');
            check(request($s,$mode,channel=>'#valid'),'repeat request rejected');drain($s);
            check(@{$s->{bot}{sent}}==1,'repeat-window guard changed');dispose($s);
        }
    });
    $group->('cleanup and a new same-channel request preserve the coalesced successor',sub {
        for my $mode (qw(manual spark)) {
            my $s=setup();check(request($s,$mode),'request rejected');
            $s->{runtime}->clear_channel('#test');change($s,'rejoin');
            check(request($s,$mode),'successor request rejected');
            check(@{$s->{workers}}==1 && $s->{fetcher}->waiter_count==2,'successor did not share pending feed');
            drain($s);
            check(@{$s->{bot}{sent}}==1 && !@{$s->{bot}{notices}},'old completion consumed or duplicated successor');
            check(!$s->{runtime}->channel_pending('#test'),'successor held reservation');dispose($s);
        }
    });
    return \@out;
}
unless (caller) {print $json->encode(run_checks()),"\n"}
1;
