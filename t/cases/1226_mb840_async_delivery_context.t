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
done_testing;
