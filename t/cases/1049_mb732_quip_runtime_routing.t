use strict;
use warnings;
use utf8;
use Mediabot::AI::ConversationRuntimeState;
use Mediabot::AI::ConversationDryRun;
use Mediabot::AI::ConversationObserver;
use Mediabot::AI::ConversationEmission;
use Mediabot::AI::ConversationSender;

{
    package MB732Runtime::Executor;
    sub new { bless { calls=>[], pending=>[] },shift }
    sub submit_dryrun {
        my($self,%args)=@_;push @{$self->{calls}},\%args;push @{$self->{pending}},$args{on_done};return 1;
    }
    sub complete {
        my($self)=@_;my $cb=shift @{$self->{pending}};
        $cb->({ok=>1,action=>'reply',reason=>'model_reply',text=>'A plan with a very optimistic relationship to reality.',provider=>'openai'}) if $cb;
    }
    package MB732Runtime::Conf;
    sub new { bless { 'main.WIT_SEND_ARMED'=>1,'main.MAIN_PROG_CMD_CHAR'=>'!' },shift }
    sub get { $_[0]{$_[1]} }
    sub get_int { $_[0]{$_[1]} // 0 }
    package MB732Runtime::Logger;
    sub new { bless { lines=>[] },shift }
    sub log { push @{$_[0]{lines}},$_[2] }
    package MB732Runtime::IRC;
    sub new { bless {},shift }
    sub nick { 'Bot' }
    package MB732Runtime::SparkState;
    sub snapshot { return { event_active=>1 } }
}

return sub {
    my($a)=@_;
    my $main=do { open my $fh,'<:encoding(UTF-8)','mediabot.pl' or die $!;local $/;<$fh> };
    my $helpers='';
    for my $name (qw(_spark_game_active _conversation_busy _wit_send_transport _wit_sync_sender_arm)) {
        my($source)=$main =~ /(sub \Q$name\E \{.*?\n\})/s;
        die "Missing runtime helper $name" unless defined $source;
        $helpers.=$source."\n";
    }
    my $ok=eval 'package MB732Runtime; use strict; use warnings; '.$helpers.' 1;';
    die $@ unless $ok;
    my($block)=$main =~ /(\# mb700-G: \+Wit.*?)(?=\n\s*my \(\$sCommand,\@tArgs\))/s;
    die 'Missing shared runtime block' unless defined $block;
    my $hook=eval 'package MB732Runtime; sub { my($mediabot,$self,$where,$who,$line,$from_conversation_bot)=@_;'.$block.' }';
    die $@ unless $hook;

    no warnings 'redefine';
    local *Mediabot::Helpers::chanset_enabled=sub { my($bot,$channel,$flag)=@_;return $bot->{flags}{$flag} || 0 };
    local *Mediabot::Helpers::channel_lang=sub { 'en' };
    local *Mediabot::Helpers::botPrivmsg=sub {
        my($bot,$channel,$text,$options)=@_;
        push @{$bot->{wire}},[$channel,$text,$options];return 1;
    };
    my $unicode_bot={wire=>[]};
    $a->is(MB732Runtime::_wit_send_transport($unicode_bot,'#test','é' x 200),1,'mb732: 400-byte Unicode reply fits one wire message');
    $a->is(MB732Runtime::_wit_send_transport($unicode_bot,'#test','é' x 201),0,'mb732: longer Unicode reply cannot split into a second message');
    $a->is(MB732Runtime::_wit_send_transport($unicode_bot,'#test','🦉' x 101),0,'mb732: emoji-heavy reply obeys byte limit too');
    $a->is(scalar @{$unicode_bot->{wire}},1,'mb732: oversized replies never reach the shared helper');
    for my $mode (qw(wit quip mixed)) {
        for my $scenario (qw(deliver revoke disarm rejoin)) {
            my $clock=1000;
            my $executor=MB732Runtime::Executor->new;
            my $bot={ flags=>{Wit=>$mode ne 'quip',Quip=>$mode ne 'wit'},
                conf=>MB732Runtime::Conf->new,logger=>MB732Runtime::Logger->new,wire=>[],
                wit_runtime_state=>Mediabot::AI::ConversationRuntimeState->new,
                wit_dryrun=>Mediabot::AI::ConversationDryRun->new(executor=>$executor,clock=>sub{$clock}) };
            $bot->{wit_runtime_state}->mark_connected;
            $bot->{wit_runtime_state}->mark_joined('#test');
            my $irc=MB732Runtime::IRC->new;
            $hook->($bot,$irc,'#test','Alice','My plan cannot fail.',0);$clock++;
            $hook->($bot,$irc,'#test','Bob','Like the last three?',0);$clock++;
            $hook->($bot,$irc,'#test','Alice','This one has a spreadsheet.',0);
            $a->is(scalar @{$executor->{calls}},1,"mb732: actual $mode hook submits once ($scenario)");
            $bot->{flags}{$mode eq 'wit'?'Wit':'Quip'}=0 if $scenario eq 'revoke';
            $bot->{conf}{'main.WIT_SEND_ARMED'}=0 if $scenario eq 'disarm';
            if($scenario eq 'rejoin') {
                $bot->{wit_runtime_state}->mark_left('#test');$bot->{wit_runtime_state}->mark_joined('#test');
            }
            $executor->complete;
            $a->is(scalar @{$bot->{wire}},$scenario eq 'deliver'?1:0,"mb732: actual $mode hook respects $scenario");
            if($scenario eq 'deliver') {
                $a->ok($bot->{wire}[0][2]{no_defer},'mb732: shared transport requests immediate-only delivery');
            }
        }
    }

    for my $busy (qw(game spark flood_queue)) {
        my $clock=2000;my $ex=MB732Runtime::Executor->new;
        my $bot={ flags=>{Quip=>1,Wit=>1},conf=>MB732Runtime::Conf->new,
            logger=>MB732Runtime::Logger->new,wire=>[],
            wit_runtime_state=>Mediabot::AI::ConversationRuntimeState->new,
            wit_dryrun=>Mediabot::AI::ConversationDryRun->new(executor=>$ex,clock=>sub{$clock}) };
        $bot->{wit_runtime_state}->mark_connected;$bot->{wit_runtime_state}->mark_joined('#test');
        my $irc=MB732Runtime::IRC->new;
        for my $pair (['Alice','A confident claim.'],['Bob','A skeptical reply.'],['Alice','Some cheerful banter.']) {
            $hook->($bot,$irc,'#test',@$pair,0);$clock++;
        }
        $bot->{_trivia}{'#test'}{active}=1 if $busy eq 'game';
        $bot->{spark_state}=bless {},'MB732Runtime::SparkState' if $busy eq 'spark';
        $bot->{_flood_outq}{'#test'}{items}=[['privmsg','queued']] if $busy eq 'flood_queue';
        $ex->complete;
        $a->is(scalar @{$bot->{wire}},0,"mb732: late $busy state blocks combined reply");
    }
    my $off={ flags=>{},logger=>MB732Runtime::Logger->new };
    $hook->($off,MB732Runtime::IRC->new,'#test','Alice','No opt-in.',0);
    $a->ok(!exists $off->{wit_dryrun},'mb732: no flags means no provider runtime creation');

    # Run the actual helper body with deterministic transport/DB boundaries.
    my $helper_source=do { open my $fh,'<:encoding(UTF-8)','Mediabot/Helpers.pm' or die $!;local $/;<$fh> };
    my($privmsg)=$helper_source =~ /(sub botPrivmsg \{.*?\n\})/s;
    die 'Missing transport helper' unless $privmsg;
    my $helper_ok=eval 'package MB732Transport; use strict; use warnings; use Encode qw(encode);'.$privmsg.' 1;';
    die $@ unless $helper_ok;
    local *MB732Transport::_is_irc_channel_target=sub { $_[0] =~ /^#/ };
    local *MB732Transport::_sanitize_irc_text=sub { $_[0] };
    local *MB732Transport::getIdChansetList=sub { $_[1] eq 'AntiFlood'?1:undef };
    local *MB732Transport::getIdChannelSet=sub { 1 };
    local *MB732Transport::checkAntiFlood=sub { 1 };
    local *MB732Transport::_defer_flooded_send=sub { $_[0]{queued}++;1 };
    my $transport_bot={logger=>MB732Runtime::Logger->new,queued=>0};
    $a->is(MB732Transport::botPrivmsg($transport_bot,'#test','A stale quip.',{no_defer=>1}),0,'mb732: real helper drops a contextual reply under antiflood');
    $a->is($transport_bot->{queued},0,'mb732: dropped conversational reply cannot reappear in the deferred queue');
    $a->is(MB732Transport::botPrivmsg($transport_bot,'#test','An ordinary message.'),1,'mb732: ordinary callers retain queue acknowledgement');
    $a->is($transport_bot->{queued},1,'mb732: ordinary output still uses the existing queue');
};
