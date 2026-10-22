use strict;
use warnings;
use Test::More;
use lib '.', 't/lib';
use Mediabot::CommandAsync;
use MB840AsyncFixture qw(fixture pump record_output);

no warnings qw(redefine once);
local *Mediabot::Helpers::botPrivmsg=\&record_output;
local *Mediabot::Helpers::botNotice=\&record_output;
local *Mediabot::Helpers::botAction=\&record_output;

for my $mode (qw(healthy replace disconnected quit left rejoined shutdown state_replaced)) {
    my ($bot,$ctx,$loop)=fixture();
    ok(Mediabot::CommandAsync::run_ctx_async($bot,$ctx,'stats',sub {
        Mediabot::Helpers::botPrivmsg($bot,'#test','first');
        Mediabot::Helpers::botNotice($bot,'Caller','second');
        Mediabot::Helpers::botAction($bot,'#test','third');
    }),"$mode: real fork worker starts");
    if ($mode eq 'replace') {$bot->{irc}=bless({connected=>1},'MB840AsyncFixture::IRC')}
    elsif ($mode eq 'disconnected') {$bot->{irc}{connected}=0}
    elsif ($mode eq 'quit') {$bot->{quit}=1}
    elsif ($mode eq 'left') {$bot->{wit_runtime_state}->mark_left('#test')}
    elsif ($mode eq 'rejoined') {$bot->{wit_runtime_state}->mark_left('#test');$bot->{wit_runtime_state}->mark_joined('#test')}
    elsif ($mode eq 'shutdown') {$bot->{wit_runtime_state}->mark_shutdown}
    elsif ($mode eq 'state_replaced') {
        my $s=Mediabot::AI::ConversationRuntimeState->new;
        $s->mark_connected;$s->mark_joined('#test');$bot->{wit_runtime_state}=$s;
    }
    ok(pump($loop,sub {!keys %{$bot->{_cmd_async_jobs}}}),"$mode: worker completes and releases its channel slot");
    is(scalar @{$bot->{out}},$mode eq 'healthy'?3:0,"$mode: only current-context output reaches helpers");
    is(scalar(Mediabot::CommandAsync::async_jobs_snapshot($bot)->@*),0,"$mode: no active job remains");
}

for my $kind (qw(failure truncated)) {
    my ($bot,$ctx,$loop)=fixture();
    local $Mediabot::CommandAsync::MAX_INTENTS=1;
    Mediabot::CommandAsync::run_ctx_async($bot,$ctx,'stats',sub {
        die "synthetic command failure\n" if $kind eq 'failure';
        Mediabot::Helpers::botPrivmsg($bot,'#test','one');
        Mediabot::Helpers::botPrivmsg($bot,'#test','two');
    });
    $bot->{irc}=bless({connected=>1},'MB840AsyncFixture::IRC');
    ok(pump($loop,sub {!keys %{$bot->{_cmd_async_jobs}}}),"$kind: stale worker is finalized");
    is(scalar @{$bot->{out}},0,"$kind: auxiliary notices also stay off the replacement connection");
}

{
    my ($bot,$ctx,$loop)=fixture();
    $bot->{after_line}=sub {$bot->{irc}=bless({connected=>1},'MB840AsyncFixture::IRC')};
    Mediabot::CommandAsync::run_ctx_async($bot,$ctx,'stats',sub {
        Mediabot::Helpers::botPrivmsg($bot,'#test','one');
        Mediabot::Helpers::botPrivmsg($bot,'#test','two');
    });
    ok(pump($loop,sub {!keys %{$bot->{_cmd_async_jobs}}}),'replacement during delivery does not block completion');
    is_deeply($bot->{out},[['#test','one']],'context is checked again between individual intents');
}

{
    my ($bot,$ctx,$loop)=fixture(channel=>undef);
    Mediabot::CommandAsync::run_ctx_async($bot,$ctx,'stats',sub {Mediabot::Helpers::botNotice($bot,'Caller','private')});
    ok(pump($loop,sub {!keys %{$bot->{_cmd_async_jobs}}}),'private worker completes without channel-generation lookup');
    is_deeply($bot->{out},[['Caller','private']],'current private transport preserves normal reply');
}

{
    my ($bot,$ctx,$loop)=fixture();
    local $Mediabot::CommandAsync::NEWS_OUTPUT_STEP=3600;
    Mediabot::CommandAsync::run_ctx_async($bot,$ctx,'actualites',sub {
        Mediabot::Helpers::botPrivmsg($bot,'#test','opening');
        Mediabot::Helpers::botPrivmsg($bot,'#test','links');
    });
    ok(pump($loop,sub {!keys %{$bot->{_cmd_async_jobs}}}),'news worker completes into paced parent queue');
    is_deeply($bot->{out},[['#test','opening']],'news pacing still sends the first line only');
    $bot->{wit_runtime_state}->mark_left('#test');$bot->{wit_runtime_state}->mark_joined('#test');
    $bot->{_news_output_q}{last_at}-=3601;
    $bot->{_news_output_q}{timer}->invoke_event('on_expire');
    is_deeply($bot->{out},[['#test','opening']],'queued news retains its channel lifecycle binding');
    ok(!$bot->{_news_output_q}{timer},'discarding obsolete news leaves no active pacing timer');
}

{
    my ($bot,$ctx,$loop)=fixture();
    local $Mediabot::CommandAsync::NEWS_OUTPUT_STEP=3600;
    for my $label (qw(old new)) {
        if ($label eq 'new') {
            $bot->{wit_runtime_state}->mark_left('#test');
            $bot->{wit_runtime_state}->mark_joined('#test');
        }
        Mediabot::CommandAsync::run_ctx_async($bot,$ctx,'actualites',sub {
            Mediabot::Helpers::botPrivmsg($bot,'#test',"$label opening");
            Mediabot::Helpers::botPrivmsg($bot,'#test',"$label links");
        });
        ok(pump($loop,sub {!keys %{$bot->{_cmd_async_jobs}}}),"$label news worker completes");
    }
    $bot->{_news_output_q}{last_at}-=3601;
    $bot->{_news_output_q}{timer}->invoke_event('on_expire');
    is_deeply($bot->{out},[['#test','old opening'],['#test','new opening']],
        'dropping stale queued news preserves the next valid batch and its pacing');
    $bot->{_news_output_q}{last_at}-=3601;
    $bot->{_news_output_q}{timer}->invoke_event('on_expire');
    is($bot->{out}[-1][1],'new links','current batch completes after the stale one is discarded');
}

# MB913: exercise real fork/pipe/watch_process with byte-heavy results.
{
    require JSON::PP;
    require IO::Async::Stream;
    require IO::Async::Loop;
    my $new = IO::Async::Stream->can('new');
    my $watch = IO::Async::Loop->can('watch_process');
    my $limit = $Mediabot::CommandAsync::MAX_PAYLOAD;
    my $overhead = length(JSON::PP::encode_json({ok=>1,
        intents=>[['privmsg','#test','']],wlogs=>[]}));
    my @vectors = (
        {name=>'unicode_nominal',lines=>[['privmsg','#test',"caf\x{e9} \x{1f989}"],
            ['notice','Caller','second'],['action','#test','third']],log=>"log caf\x{e9} \x{1f989}",keep=>3},
        {name=>'exact_bytes',lines=>[['privmsg','#test','x' x ($limit-$overhead)]],keep=>1,exact=>1},
        {name=>'huge_first',lines=>[['privmsg','#test','x' x 70000]],keep=>0,truncated=>1},
        {name=>'huge_tail',lines=>[['privmsg','#test','first'],['privmsg','#test','x' x 70000]],keep=>1,truncated=>1},
        {name=>'crowded_prefix',lines=>[map {['privmsg','#test',"$_:".('x' x 10000)]} 1..60],keep=>6,truncated=>1},
        {name=>'logs_overflow',lines=>[['privmsg','#test','first'],['notice','Caller','second'],
            ['action','#test','third']],log=>'x' x 70000,keep=>3,truncated=>1},
        {name=>'oversize_stale',lines=>[['privmsg','#test','first'],['privmsg','#test','x' x 70000]],
            keep=>1,truncated=>1,stale=>1},
        {name=>'command_failure',lines=>[],failure=>1,keep=>0},
    );
    for my $v (@vectors) {
        my ($bot,$ctx,$loop)=fixture();my ($wire,$pid,$status)=('',undef,undef);
        local $Mediabot::CommandAsync::TIMEOUT_S=1;
        local $Mediabot::CommandAsync::KILL_AFTER_S=0.05;
        local *IO::Async::Stream::new=sub {
            my ($class,%args)=@_;my $read=$args{on_read};
            $args{on_read}=sub {
                $wire.=${$_[1]};
                return $read->(@_);
            };
            return $new->($class,%args);
        };
        local *IO::Async::Loop::watch_process=sub {
            my ($l,$child,$cb)=@_;$pid=$child;
            return $watch->($l,$child,sub {$status=$_[1];$cb->(@_)});
        };
        my @warnings;
        my ($started,$done,$error);
        {
            local $SIG{__WARN__}=sub {push @warnings,@_};
            eval {
                $started=Mediabot::CommandAsync::run_ctx_async($bot,$ctx,'stats',sub {
                    $bot->{logger}->log(3,$v->{log}) if exists $v->{log};
                    die "MB913 command failed\n" if $v->{failure};
                    for my $line (@{$v->{lines}}) {
                        if ($line->[0] eq 'privmsg') {Mediabot::Helpers::botPrivmsg($bot,@$line[1,2])}
                        elsif ($line->[0] eq 'notice') {Mediabot::Helpers::botNotice($bot,@$line[1,2])}
                        else {Mediabot::Helpers::botAction($bot,@$line[1,2])}
                    }
                });
                $bot->{irc}=bless({connected=>1},'MB840AsyncFixture::IRC') if $v->{stale};
                $done=pump($loop,sub {!keys %{$bot->{_cmd_async_jobs}}});
                1;
            } or $error=$@ || 'worker failed';
        }
        my $data=eval {JSON::PP::decode_json($wire)};
        my $stats=Mediabot::CommandAsync::async_stats_snapshot($bot);
        my @expected=map {[$_->[1],$_->[2]]} @{$v->{lines}}[0..$v->{keep}-1];
        push @expected,['Caller','stats: output truncated (too many lines for one run).'] if $v->{truncated};
        @expected=(['Caller','Database error.']) if $v->{failure};
        @expected=() if $v->{stale};
        my $same=$started && $done && !$error && !@warnings && defined($pid) && defined($status) && $status==0
            && !keys(%{$bot->{_cmd_async_jobs}}) && $stats->{timeouts}==0 && $stats->{fallback_sync}==0
            && $stats->{completed}==($v->{failure} || $v->{stale}?0:1)
            && length($wire)<=$limit && ref($data) eq 'HASH'
            && $data->{ok}==($v->{failure}?0:1)
            && !!$data->{truncated}==!!$v->{truncated}
            && JSON::PP->new->canonical->encode($bot->{out}) eq JSON::PP->new->canonical->encode(\@expected);
        if ($data && !$v->{failure}) {
            $same &&= ref($data->{intents}) eq 'ARRAY'
                && @{$data->{intents}}==$v->{keep}
                && !grep {ref($_) ne 'ARRAY' || @$_!=3} @{$data->{intents}};
        }
        $same &&= length($wire)==$limit if $v->{exact};
        $same &&= ($data->{stage}//'') eq 'command' && ($data->{detail}//'') =~ /MB913 command failed/
            if $v->{failure};
        $same &&= @{$data->{wlogs}}==1 && $data->{wlogs}[0][1] eq $v->{log}
            if $v->{name} eq 'unicode_nominal' && $data;
        ok($same,"mb913: $v->{name} preserves bounded JSON, ordered output and native completion")
            or diag(JSON::PP->new->ascii->encode({bytes=>length($wire),stats=>$stats,error=>$error,
                warnings=>\@warnings,output_lines=>scalar(@{$bot->{out}})}));
    }
}
done_testing;
