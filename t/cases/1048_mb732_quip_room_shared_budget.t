use strict;
use warnings;
use utf8;
use JSON::PP ();
use Mediabot::AI::ConversationRoom;
use Mediabot::AI::QuipRequest qw(build_quip_request);
use Mediabot::AI::ConversationDryRun qw(format_ai_dryrun_log);
use Mediabot::AI::ConversationExecutor;
use Mediabot::AI::ConversationSender;

{
    package MB732::Executor;
    sub new { bless { calls => [], pending => [], fail => 0 }, shift }
    sub submit_dryrun {
        my ($self, %args) = @_;
        push @{ $self->{calls} }, { %args };
        if ($self->{fail}) {
            $args{on_done}->({ ok => 0, action => 'no_reply', reason => 'provider_error' });
            return 0;
        }
        push @{ $self->{pending} }, $args{on_done};
        return 1;
    }
    sub complete {
        my ($self, $action) = @_;
        my $cb = shift @{ $self->{pending} };
        $cb->({ ok => 1, action => $action || 'reply', reason => 'model_reply',
            text => 'The plan has more confidence than evidence.', provider => 'openai' }) if $cb;
    }
    package MB732::Client;
    sub new { bless { requests => [] }, shift }
    sub execute { my ($self,$request)=@_;push @{$self->{requests}},$request;return {ok=>1,answer=>'NO_REPLY'} }
    sub submit { my($self,$request,%opts)=@_;$opts{on_done}->($self->execute($request));return 1 }
}

return sub {
    my ($a) = @_;
    my $now = 1000;
    my $room = Mediabot::AI::ConversationRoom->new(clock => sub { $now });
    my $say = sub {
        my ($nick,$text,%extra)=@_;
        return $room->observe_public_line(channel=>'#room',nick=>$nick,bot_nick=>'Bot',
            message=>$text,command_char=>'!',room_generation=>1,%extra);
    };
    $a->is($say->('Alice','This plan cannot fail.')->{reason},'room_warming','mb732: first line is not a room');
    $a->is($say->('Alice','I checked it myself.')->{ready},0,'mb732: a monologue does not invite a pile-on');
    my $ready=$say->('Bob','Like the previous three plans?');
    $a->ok($ready->{ready},'mb732: three lines and two humans form recent context');
    $a->is($ready->{context}[0]{speaker},'speaker1','mb732: first local identity becomes speaker1');
    $a->is($ready->{context}[2]{speaker},'speaker2','mb732: second local identity gets a separate label');
    my $r=build_quip_request(style=>'quip',language=>'en',message=>'Like the previous three plans?',
        context=>$ready->{context});
    $a->is($r->{provider},'auto','mb732: Quip always uses provider auto');
    $a->ok(!exists($r->{model}),'mb732: no provider-specific model is pinned');
    $a->is($r->{purpose},'quip','mb732: provider telemetry identifies Quip');
    $a->is(scalar @{$r->{messages}},1,'mb732: context and current line form one provider request');
    $a->unlike($r->{messages}[0]{content},qr/Alice|Bob|#room/,'mb732: identity/channel metadata is not sent');
    $a->like($r->{system},qr/NO_REPLY/,'mb732: silence is an explicit model outcome');
    $a->like($r->{system},qr/untrusted conversation data/,'mb732: context cannot override instructions');
    $a->like($r->{system},qr/arguing seriously/,'mb732: sharp humor yields to serious conversation');
    $a->like($r->{system},qr/do not humiliate|do not.*pile/i,'mb732: no personal pile-on');
    my $mixed=build_quip_request(style=>'mixed',language=>'fr',message=>'Une idée.',context=>$ready->{context});
    $a->like($mixed->{system},qr/at most ONE reply/,'mb732: combined mode gets one reply, not one per flag');
    $a->like($mixed->{system},qr/French/,'mb732: channel language reaches the prompt');
    for my $provider ('openai','anthropic','gemini',undef) {
        my $ok=eval { build_quip_request(provider=>$provider,message=>'text',context=>$ready->{context});1 };
        $a->ok(!$ok,'mb732: explicit/non-auto provider cannot override Quip');
    }
    for my $bad ([],[{$ready->{context}[0]->%*}],[(map {{speaker=>'real-nick',text=>'text'}} 1..3)]) {
        my $ok=eval { build_quip_request(message=>'text',context=>$bad);1 };
        $a->ok(!$ok,'mb732: inadequate context and identity-bearing labels are rejected');
    }
    my $fingerprint=$ready->{fingerprint};
    $now++;
    $a->is($say->('AutoFeed','private bot output',from_bot=>1)->{reason},'room_busy','mb732: bots create breathing space');
    $a->is($room->snapshot('#room')->{fingerprint},$fingerprint,'mb732: bot text does not enter human context');
    $now+=31;
    $a->ok($room->snapshot('#room')->{ready},'mb732: room becomes eligible after breathing space');
    $a->is($say->('Alice','!shop 21')->{reason},'room_busy','mb732: game/other commands also create breathing space');
    $now+=31;
    $room->note_delivery('#room','An earlier delivered line.');
    $a->is($room->snapshot('#room')->{previous_reply},'An earlier delivered line.','mb732: recent real delivery informs repetition avoidance');
    $now+=301;
    $a->is($room->snapshot('#room')->{ready},0,'mb732: old conversation expires');
    $a->is($room->snapshot('#room')->{previous_reply},'','mb732: old reply expires too');
    for my $i (1..10) { $say->('Person'.$i,('x' x 500)); }
    my $bounded=$room->snapshot('#room');
    $a->is(scalar @{$bounded->{context}},8,'mb732: room retains only eight lines');
    $a->is(length($bounded->{context}[0]{text}),240,'mb732: each line is bounded');
    $a->ok(eval { build_quip_request(message=>'text',context=>$bounded->{context});1 },'mb732: eight distinct speakers still fit the request contract');
    $a->is($say->('Alice','After reconnect.',room_generation=>2)->{ready},0,'mb732: reconnect generation clears old context');

    my $make=sub {
        my $clock=2000;my $exec=MB732::Executor->new;
        my $runtime=Mediabot::AI::ConversationDryRun->new(executor=>$exec,clock=>sub{$clock});
        my (@obs,@results,@candidates);
        my $line=sub {
            my($style,$nick,$text,%extra)=@_;
            return $runtime->handle_public_line(enabled=>1,channel=>'#test',nick=>$nick,bot_nick=>'Bot',
                message=>$text,style=>$style,language=>'en',command_char=>'!',%extra,
                on_observation=>sub{push @obs,shift},on_result=>sub{push @results,shift},
                on_candidate=>sub{push @candidates,shift});
        };
        return ($runtime,$exec,\$clock,$line,\@obs,\@results,\@candidates);
    };
    for my $style (qw(quip mixed)) {
        my($rt,$ex,$clock,$line,$obs,$res,$out)=$make->();
        $line->($style,'Alice','This plan cannot fail.');$$clock++;
        $line->($style,'Bob','We heard that before.');$$clock++;
        $a->is($line->($style,'Alice','This time I made a spreadsheet.'),1,"mb732: $style starts once after warmup");
        $a->is(scalar @{$ex->{calls}},1,"mb732: $style has one provider request");
        $a->is($ex->{calls}[0]{provider},'auto',"mb732: $style submits auto");
        $a->ok($rt->channel_inflight('#test'),"mb732: Spark sees $style through the shared pending signal");
        $ex->complete;
        $a->is(scalar @$out,1,"mb732: $style creates exactly one candidate");
        $line->('wit','Bob','Switching mode immediately.');
        $a->is($obs->[-1]{reason},'cooldown',"mb732: $style and Wit share request cooldown");
        $a->is(scalar @{$ex->{calls}},1,"mb732: mode switching adds no request");
        $a->unlike(format_ai_dryrun_log('#test',$res->[0]),qr/spreadsheet|evidence|Alice/,'mb732: Quip diagnostics contain no conversation or reply');
    }
    for my $failure (qw(human_change repeated_line expired bot_output provider_failure model_silence busy)) {
        my($rt,$ex,$clock,$line,$obs,$res,$out)=$make->();
        $line->('quip','Alice','Repeated human line.');$$clock++;
        $line->('quip','Bob','Repeated human line.');$$clock++;
        $ex->{fail}=1 if $failure eq 'provider_failure';
        $line->('quip','Alice','Repeated human line.',context_blocked=>$failure eq 'busy');
        if ($failure eq 'busy') {
            $a->is(scalar @{$ex->{calls}},0,'mb732: peer activity prevents a request');next;
        }
        if ($failure eq 'human_change' || $failure eq 'repeated_line') {
            $$clock++;
            $line->('quip','Bob',$failure eq 'human_change'?'Now a different subject.':'Repeated human line.');
        }
        $$clock+=31 if $failure eq 'expired';
        $rt->note_bot_pressure('#test') if $failure eq 'bot_output';
        $ex->complete($failure eq 'model_silence'?'no_reply':'reply');
        $a->is(scalar @$out,0,"mb732: $failure never emits a candidate");
        $a->is(scalar @{$ex->{calls}},1,"mb732: $failure never tries another mode");
        if ($failure eq 'provider_failure') {
            $line->('wit','Bob','Retry after provider error.');
            $a->is(scalar @{$ex->{calls}},1,'mb732: failed auto request still spends shared interval');
        }
    }
    my $client=MB732::Client->new;
    my $executor=Mediabot::AI::ConversationExecutor->new(client=>$client);
    my $result=$executor->execute_dryrun(style=>'mixed',provider=>'auto',language=>'en',
        message=>'An actual detail.',context=>$ready->{context});
    $a->is($result->{action},'no_reply','mb732: real executor preserves model abstention');
    $a->is($client->{requests}[0]{purpose},'wit_quip','mb732: executor uses the mixed prompt through the existing client');

    my $send_time=4000;my @wire;
    my $sender=Mediabot::AI::ConversationSender->new(clock=>sub{$send_time},send_cb=>sub{push @wire,[@_];1});
    $sender->arm;
    my %send=(channel=>'#test',text=>'A single contextual line.',request_generation=>1,
        state_cb=>sub{{enabled=>1,runtime_active=>1,irc_connected=>1,channel_joined=>1,current_generation=>1}});
    $a->is($sender->attempt_send(%send)->{action},'sent','mb732: first common sender delivery works');
    $send_time+=90;
    $a->is($sender->attempt_send(%send)->{reason},'rate_limited','mb732: another mode cannot use the 90s provider interval to bypass 120s delivery');
    $send_time+=30;
    $a->is($sender->attempt_send(%send)->{action},'sent','mb732: shared sender becomes eligible at 120s');
    $a->is(scalar @wire,2,'mb732: no second queue or sender was created');
};
