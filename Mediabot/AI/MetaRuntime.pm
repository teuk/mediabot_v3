package Mediabot::AI::MetaRuntime;
use strict;
use warnings;
use utf8;
use Digest::SHA qw(sha256_hex);
use Encode qw(encode);
use File::Basename qw(dirname);
use File::Spec;
use JSON::PP ();
use Mediabot::Helpers ();
use Mediabot::AI qw(provider_configured);
use Mediabot::AI::Client;
use Mediabot::AI::IRCOutput qw(format_ai_reply);
use Mediabot::AI::Transport ();
use Mediabot::AI::MetaPolicy qw(settings fold clean safe_url);
use Mediabot::AI::MetaMemory;
use Mediabot::AI::MetaWeb;
use Mediabot::AI::MetaChat;
use Mediabot::AI::MetaReply qw(clean_answer format_meta_reply shorten_sources display_urls shorturl_ready);
use Mediabot::AI::MetaKnowledge ();

sub new {
    my ($class,%args)=@_;
    return bless {bot=>$args{bot},clock=>$args{clock}||sub {time},
        jobs=>{},rate=>{},memories=>{},client_factory=>$args{client_factory},
        web_start=>$args{web_start},schedule_cb=>$args{schedule_cb},shorten_start=>$args{shorten_start}},$class;
}
sub _signature {
    my ($self,$cfg)=@_;
    return sha256_hex(JSON::PP->new->canonical->utf8->encode($cfg));
}
sub _enabled {
    my ($self,$cfg,$channel)=@_;
    return 0 unless $cfg->{enabled} && $cfg->{channels}{fold($channel)};
    return eval {Mediabot::Helpers::chanset_enabled($self->{bot},$channel,'chatGPT',default=>0)} ? 1:0;
}
sub _identity {
    my ($bot,$message,$nick)=@_;
    my (undef,$ident,$host)=eval {$bot->getMessageNickIdentHost($message)};
    return undef unless defined($ident) && !ref($ident) && length($ident)
        && defined($host) && !ref($host) && length($host);
    return join('!',fold($nick),$ident,$host);
}
sub _memory {
    my ($self,$cfg)=@_;my $bot=$self->{bot};
    my $file=File::Spec->rel2abs($bot->{config_file}//'mediabot.conf');
    my $base=dirname($file);
    my $configured=$cfg->{state_file};
    my $path=length($configured) ? File::Spec->rel2abs($configured,$base)
        : File::Spec->catfile($base,'cache','meta-ai-'.substr(sha256_hex($file),0,16).'.json');
    my $key=join('\0',$path,$cfg->{memory_ttl},$cfg->{memory_turns});
    return $self->{memories}{$key}||=Mediabot::AI::MetaMemory->new(
        path=>$path,ttl=>$cfg->{memory_ttl},turns=>$cfg->{memory_turns},clock=>$self->{clock});
}
sub _scope {
    my ($self,$channel)=@_;
    my $bot=$self->{bot};
    return join("\0",File::Spec->rel2abs($bot->{config_file}//'mediabot.conf'),
        eval {$bot->{conf}->get('connection.CONN_SERVER_NETWORK')} // 'unknown',fold($channel));
}
sub _notice {
    my ($self,$nick,$lang,$reason)=@_;
    my %text=(
        busy=>['Une réponse est déjà en cours ici. Réessaie après sa réception.','An answer is already in progress here. Please wait for it.'],
        rate=>['La limite des questions IA est atteinte. Réessaie dans une minute.','The AI question limit was reached. Please try again in a minute.'],
        daily_limit=>['Le budget quotidien des questions IA est atteint.','The daily AI question budget was reached.'],
        not_enough_providers=>['Le mode collectif nécessite au moins deux providers configurés.','Collective mode needs at least two configured providers.'],
        memory=>['La mémoire de conversation est indisponible. La question n’a pas été envoyée.','Conversation memory is unavailable. The question was not sent.'],
        forgotten=>['Tes échanges avec le bot ont été effacés de ce canal.','Your exchanges with the bot were removed from this channel.'],
        web=>['Je n’ai pas pu vérifier les informations actuelles sur le web. Réessaie un peu plus tard.','I could not verify the current information on the web. Please try again later.'],
        failed=>['Je n’ai pas obtenu de réponse exploitable. Réessaie un peu plus tard.','I could not obtain a usable answer. Please try again later.'],
    );
    my $pair=$text{$reason}||$text{failed};
    Mediabot::Helpers::botNotice($self->{bot},$nick,$pair->[$lang eq 'fr'?0:1]);
}
sub _alive {
    my ($self,$channel,$generation,$signature,$memory,$ticket)=@_;
    my $bot=$self->{bot};my $cfg=settings($bot->{conf});
    return 0 unless $self->_signature($cfg) eq $signature && $self->_enabled($cfg,$channel);
    my $current=eval {$bot->{wit_runtime_state}->capture_generation($channel)};
    return 0 unless defined($current) && $current==$generation;
    return eval {$memory->current($ticket)} ? 1:0;
}
sub _emit {
    my ($self,$channel,$chunks,$cfg,$alive,$complete,$sender)=@_;
    my $index=0;my @sent;my $pump;
    $pump=sub {
        unless ($alive->()) {$complete->(undef);$pump=undef;return}
        my $ok=eval {$sender ? $sender->($chunks->[$index])
            : Mediabot::Helpers::botPrivmsg($self->{bot},$channel,$chunks->[$index],{no_defer=>1})};
        unless ($ok) {$complete->(undef);$pump=undef;return}
        push @sent,$chunks->[$index++];
        if ($index>=@$chunks) {$complete->(join(' ',@sent));$pump=undef;return}
        if ($self->{schedule_cb}) {$self->{schedule_cb}->($cfg->{pacing_us}/1_000_000,$pump);return}
        require IO::Async::Timer::Countdown;
        my $loop=Mediabot::AI::Transport::usable_loop($self->{bot});
        unless ($loop) {$complete->(undef);$pump=undef;return}
        my $timer; $timer=IO::Async::Timer::Countdown->new(delay=>$cfg->{pacing_us}/1_000_000,
            on_expire=>sub {$loop->remove($timer);$timer=undef;$pump->() if $pump});
        $loop->add($timer);$timer->start;
    };
    unless (@$chunks) {$complete->(undef);return}
    $pump->();
}
sub _source_line {
    my ($sources,$lang,$urls)=@_;my $line=$lang eq 'fr'?'Sources : ':'Sources: ';my $count=0;
    $urls={} unless ref($urls) eq 'HASH';
    for my $source (@$sources) {
        next unless ref($source) eq 'HASH';my $url=safe_url($source->{url});next unless $url;
        if (defined($urls->{$url}) && $urls->{$url} ne $url) {
            # IRC colour 12 is light blue; underline and reset are scoped to
            # this verified private-service alias, never to the separator.
            $url="\x0312\x1f".$urls->{$url}."\x0f";
        }
        my $candidate=$line.($count?' | ':'').$url;
        next if length(encode('UTF-8',$candidate))>400;
        $line=$candidate;last if ++$count>=2;
    }
    return $count ? $line : undef;
}
sub _present_sources {
    my ($self,$sources,$done)=@_;my $finished=0;
    my $complete=sub {return if $finished++;$done->($_[0])};
    if ($self->{shorten_start}) {
        my $ok=eval {$self->{shorten_start}->($sources,$complete);1};
        $complete->({}) unless $ok;return;
    }
    unless (shorturl_ready($self->{bot})) {$complete->({});return}
    my $loop=Mediabot::AI::Transport::usable_loop($self->{bot});
    unless ($loop) {$complete->({});return}
    require Mediabot::AsyncWorker;
    my $worker=Mediabot::AsyncWorker->start(loop=>$loop,label=>'meta source presentation',
        timeout=>7,max_output=>16*1024,
        child=>sub {shorten_sources(bot=>$self->{bot},sources=>$sources)},
        on_done=>sub {
            my ($record)=@_;
            my $value=ref($record) eq 'HASH' && $record->{ok} && ref($record->{value}) eq 'HASH'?$record->{value}:{};
            if (ref($record) ne 'HASH' || !$record->{ok}) {
                eval {$self->{bot}{logger}->log(0,'[WARN] META_AI shorturl worker_failed')};
            }
            for my $event (@{ref($value->{events}) eq 'ARRAY'?$value->{events}:[]}) {
                next unless ref($event) eq 'HASH';
                my %kinds=map {$_=>1} qw(failure circuit_open recovery state_error configuration_error);
                my %categories=map {$_=>1} qw(transport rate_limit auth client service contract destination_mismatch invalid_alias invalid_config);
                my $kind=!ref($event->{kind}) && $kinds{$event->{kind}//''}?$event->{kind}:'unknown';
                my $category=!ref($event->{category}) && $categories{$event->{category}//''}?$event->{category}:'unknown';
                my $status=defined($event->{status}) && !ref($event->{status}) && $event->{status}=~/^\d{1,3}$/?$event->{status}:0;
                eval {$self->{bot}{logger}->log(0,'META_AI shorturl event='.$kind.' category='.$category.' status='.$status)};
            }
            $complete->($value);
        });
    $complete->({}) unless $worker;
}
sub _log_event {
    my ($self,$event)=@_;
    return unless ref($event) eq 'HASH';
    my $line;
    if (($event->{kind}//'') eq 'provider') {
        my $provider=defined($event->{provider}) && !ref($event->{provider})
            && $event->{provider}=~/\A(?:openai|anthropic|gemini)\z/?$event->{provider}:'unknown';
        my $outcome=defined($event->{outcome}) && !ref($event->{outcome})
            && $event->{outcome}=~/\A(?:usable|empty_draft|api_failure)\z/?$event->{outcome}:'unknown';
        my $status=defined($event->{status}) && !ref($event->{status})
            && $event->{status}=~/\A[0-5]?\d{1,2}\z/?0+$event->{status}:0;
        my %errors=map {$_=>1} qw(http_error parse_error not_configured invalid_config invalid_request
            provider_build_failed provider_failed async_unavailable worker_failed worker_launch_failed);
        my $error=$outcome eq 'usable' || $outcome eq 'empty_draft'?'none'
            :!ref($event->{error}) && $errors{$event->{error}//''}?$event->{error}:'unknown';
        my %categories=map {$_=>1} qw(quota access model request output_budget service_unavailable
            server_error timeout tls dns connection transport empty_output);
        my $category=$outcome eq 'usable' || $outcome eq 'empty_draft'?'none'
            :!ref($event->{failure_category}) && $categories{$event->{failure_category}//''}
                ?$event->{failure_category}:'unknown';
        my $retries=defined($event->{transient_retries}) && !ref($event->{transient_retries})
            && $event->{transient_retries}=~/\A[01]\z/?$event->{transient_retries}:0;
        $line='META_AI provider='.$provider.' outcome='.$outcome.' status='.$status
            .' error='.$error.' category='.$category.' retries='.$retries;
    }
    elsif (($event->{kind}//'') eq 'evidence') {
        my %reasons=map {$_=>1} qw(missing invalid mismatch invalid_ids missing_citations too_many_citations
            unknown_passage source_changed passage_ids);
        my $reason=!ref($event->{reason}) && $reasons{$event->{reason}//''}?$event->{reason}:'unknown';
        my $action=defined($event->{action}) && !ref($event->{action})
            && $event->{action}=~/\A(?:retry|rejected|accepted)\z/?$event->{action}:'unknown';
        $line='META_AI evidence='.$reason.' action='.$action;
    }
    eval {$self->{bot}{logger}->log(0,$line)} if defined $line;
}
sub _ask {
    my ($self,$message,$nick,$channel,$prompt,$cfg)=@_;
    my $bot=$self->{bot};my $lang=Mediabot::Helpers::channel_lang($bot,$channel);
    my $scope=$self->_scope($channel);my $key=fold($channel);
    my $memory=eval {$self->_memory($cfg)};
    unless ($memory) {$self->_notice($nick,$lang,'memory');return 1}
    my $actor=_identity($bot,$message,$nick);
    unless (defined $actor) {$self->_notice($nick,$lang,'failed');return 1}
    if ($prompt eq '/forget') {
        my $ok=eval {
            $memory->forget_actor($scope,$actor);
            for my $other (values %{$self->{memories}}) {
                $other->forget_actor($scope,$actor) unless $other==$memory;
            }
            1;
        };
        $self->_notice($nick,$lang,$ok?'forgotten':'memory');return 1;
    }
    my $generation=eval {$bot->{wit_runtime_state}->capture_generation($channel)};
    return 1 unless defined $generation;
    if (exists($self->{jobs}{$key}) || keys(%{$self->{jobs}})>=$cfg->{max_jobs}) {
        $self->_notice($nick,$lang,'busy');return 1;
    }
    my $now=$self->{clock}->();
    for my $bucket ($key,'__global__') {
        $self->{rate}{$bucket}=[grep {$_<=$now && $now-$_<60} @{$self->{rate}{$bucket}||[]}];
    }
    if (@{$self->{rate}{$key}}>=$cfg->{rate_max} || @{$self->{rate}{__global__}}>=$cfg->{global_rate_max}) {
        $self->_notice($nick,$lang,'rate');return 1;
    }
    my @providers=grep {provider_configured($bot->{conf},$_)} @{$cfg->{providers}};
    if (@providers<$cfg->{min_providers}) {$self->_notice($nick,$lang,'not_enough_providers');return 1}
    my $ticket=eval {$memory->begin_turn($scope,$actor,$prompt,$cfg->{daily_limit},$nick)};
    unless ($ticket) {$self->_notice($nick,$lang,'memory');return 1}
    if ($ticket->{error}) {$self->_notice($nick,$lang,$ticket->{error});return 1}
    push @{$self->{rate}{$key}},$now;push @{$self->{rate}{__global__}},$now;
    my $signature=$self->_signature($cfg);$self->{jobs}{$key}=1;
    my %overrides=('openai.API_URL'=>'https://api.openai.com/v1/responses',
        'openai.WEB_SEARCH'=>1,'openai.FALLBACK_MODEL'=>'','gemini.THINKING_LEVEL'=>'LOW',
        map {($_.'.MODEL'=>$cfg->{models}{$_})} keys %{$cfg->{models}});
    my @order=($cfg->{synthesizer},grep {$_ ne $cfg->{synthesizer}} @providers);
    my $client=eval {$self->{client_factory} ? $self->{client_factory}->(\%overrides,\@order)
        : Mediabot::AI::Client->new(conf=>$bot->{conf},loop_owner=>$bot,
            config_overrides=>\%overrides,provider_order=>\@order)};
    unless ($client) {delete $self->{jobs}{$key};$self->_notice($nick,$lang,'failed');return 1}
    my $web=Mediabot::AI::MetaWeb->new(api_key=>eval {$bot->{conf}->get('tavily.API_KEY')} // '',
        domains=>$cfg->{domains},clock=>$self->{clock});
    my $web_start=$self->{web_start} || sub {
        my ($query,$done,$plan)=@_;require Mediabot::AsyncWorker;
        my $worker=Mediabot::AsyncWorker->start(loop=>Mediabot::AI::Transport::usable_loop($bot),
            label=>'meta research',timeout=>27,max_output=>64*1024,
            child=>sub {$web->search($query,plan=>$plan)},on_done=>sub {
                my ($result)=@_;$done->(ref($result) eq 'HASH' && $result->{ok} ? $result->{value}:{ok=>0});
            });
        $done->({ok=>0}) unless $worker;
        return $worker?1:0;
    };
    my $engine=Mediabot::AI::MetaChat->new(conf=>$bot->{conf},settings=>$cfg,
        client=>$client,web=>$web,web_start=>$web_start,clock=>$self->{clock},
        on_event=>sub {$self->_log_event($_[0])},evidence_mode=>'passage_ids');
    my $completed=0;
    my $done=sub {
        my ($result)=@_;return if $completed++;
        my $alive=sub {$self->_alive($channel,$generation,$signature,$memory,$ticket)};
        unless ($alive->()) {delete $self->{jobs}{$key};return}
        unless (ref($result) eq 'HASH' && $result->{ok}) {
            delete $self->{jobs}{$key};my $error=ref($result) eq 'HASH'?$result->{error}//'failed':'failed';
            my %known=map {$_=>1} qw(failed all_providers_failed web_disabled_for_current_question
                web_unavailable synthesis_failed web_synthesis_failed web_missing_citations unsupported_web_answer
                web_missing_evidence web_evidence_mismatch);
            $error='failed' unless !ref($error) && $known{$error};
            my $contributors=ref($result) eq 'HASH' && ref($result->{contributors}) eq 'ARRAY'
                ? scalar(grep {!ref($_) && /\A(?:openai|anthropic|gemini)\z/} @{$result->{contributors}}):0;
            my $line='[WARN] META_AI failed code='.$error.' contributors='.$contributors
                .' degraded='.(ref($result) eq 'HASH' && $result->{degraded}?1:0)
                .' web_attempted='.(ref($result) eq 'HASH' && $result->{web_attempted}?1:0)
                .' citation_repair='.(ref($result) eq 'HASH' && $result->{citation_repair}?1:0);
            eval {$bot->{logger}->log(0,$line)};
            $self->_notice($nick,$lang,$error =~ /web/ ? 'web':'failed');return;
        }
        my $sources=ref($result->{sources}) eq 'ARRAY'?$result->{sources}:[];
        my $deliver=sub {
            my ($presentation)=@_;
            unless ($alive->()) {delete $self->{jobs}{$key};return}
            my $base=eval {$bot->{conf}->get('shorturl.PUBLIC_BASE_URL')}//'';
            my $urls=display_urls($sources,$presentation,$base);
            my $source_line=@$sources?_source_line($sources,$lang,$urls):undef;
            if (@$sources && !defined($source_line)) {delete $self->{jobs}{$key};$self->_notice($nick,$lang,'web');return}
            my $chunks=format_meta_reply($result->{answer});
            unless (@$chunks) {delete $self->{jobs}{$key};$self->_notice($nick,$lang,'failed');return}
            push @$chunks,$source_line if defined $source_line;
            $self->_emit($channel,$chunks,$cfg,$alive,sub {
                my ($sent)=@_;
                eval {$memory->commit_turn($ticket,$sent)} if defined $sent;
                delete $self->{jobs}{$key};
                my $shortened=grep {$urls->{$_} ne $_} keys %$urls;
                my $anchors=defined($result->{evidence_anchors}) && !ref($result->{evidence_anchors})
                    && $result->{evidence_anchors}=~/^[0-2]$/?$result->{evidence_anchors}:0;
                eval {$bot->{logger}->log(0,defined($sent)?'META_AI completed contributors='.scalar(@{$result->{contributors}||[]}).' web='.($result->{web_used}?1:0).' degraded='.($result->{degraded}?1:0).' citation_repair='.($result->{citation_repair}?1:0).' anchors='.$anchors.' shorturls='.$shortened:'[WARN] META_AI delivery_aborted')};
            });
        };
        if (@$sources) {$self->_present_sources($sources,$deliver)}
        else {$deliver->({})}
    };
    my $ok=eval {$engine->submit(messages=>$ticket->{messages},prompt=>$prompt,
        language=>$lang,on_done=>$done);1};
    $done->({ok=>0,error=>'failed'}) unless $ok;
    return 1;
}
sub _local {
    my ($self,$message,$nick,$channel,$prompt,$cfg,$plan)=@_;
    my $bot=$self->{bot};my $key=fold($channel);
    my $lang=Mediabot::Helpers::channel_lang($bot,$channel);
    if (exists($self->{jobs}{$key}) || keys(%{$self->{jobs}})>=$cfg->{max_jobs}) {
        $self->_notice($nick,$lang,'busy');return 1;
    }
    my $generation=eval {$bot->{wit_runtime_state}->capture_generation($channel)};
    return 1 unless defined $generation;
    my $now=$self->{clock}->();
    for my $bucket ($key,'__global__') {
        $self->{rate}{$bucket}=[grep {$_<=$now && $now-$_<60} @{$self->{rate}{$bucket}||[]}];
    }
    if (@{$self->{rate}{$key}}>=$cfg->{rate_max} || @{$self->{rate}{__global__}}>=$cfg->{global_rate_max}) {
        $self->_notice($nick,$lang,'rate');return 1;
    }
    push @{$self->{rate}{$key}},$now;push @{$self->{rate}{__global__}},$now;
    my $result=eval {Mediabot::AI::MetaKnowledge::answer(bot=>$bot,plan=>$plan,channel=>$channel,
        message=>$message,language=>$lang,settings=>$cfg)};
    unless (ref($result) eq 'HASH' && length($result->{text}//'')) {$self->_notice($nick,$lang,'failed');return 1}
    my $signature=$self->_signature($cfg);
    my $alive=sub {
        my $current=settings($bot->{conf});
        return 0 unless $signature eq $self->_signature($current) && $self->_enabled($current,$channel);
        my $gen=eval {$bot->{wit_runtime_state}->capture_generation($channel)};
        return 0 unless defined($gen) && $gen==$generation;
        return 0 if $result->{guard} && !$result->{guard}->();
        return 1;
    };
    my $chunks=format_ai_reply(clean_answer($result->{text}),max_lines=>2,wrap_bytes=>400,truncation_suffix=>' …');
    $self->{jobs}{$key}=1;
    my $sender=$result->{private} ? sub {Mediabot::Helpers::botNotice($bot,$nick,$_[0]);1}:undef;
    $self->_emit($channel,$chunks,$cfg,$alive,sub {
        delete $self->{jobs}{$key};
        # Protected results never enter shared memory, provider payloads or logs.
        my ($sent)=@_;
        eval {$bot->{logger}->log(0,defined($sent)?'META_AI local completed private='.($result->{private}?1:0):'[WARN] META_AI local delivery_aborted')};
    },$sender);
    return 1;
}
sub handle {
    my ($bot,$message,$nick,$channel,@words)=@_;
    my $cfg=settings($bot->{conf});
    my $runtime=$bot->{_meta_ai_runtime}||=__PACKAGE__->new(bot=>$bot);
    my $raw=join(' ',@words);my $prompt=clean($raw,4001);
    return 0 unless $prompt eq '/forget' || $runtime->_enabled($cfg,$channel);
    unless (length($prompt) && length($prompt)<=4000) {
        $runtime->_notice($nick,Mediabot::Helpers::channel_lang($bot,$channel),'failed');return 1;
    }
    my $plan=$prompt eq '/forget' ? undef : Mediabot::AI::MetaKnowledge::plan($bot,$prompt,$runtime->{clock}->());
    return $runtime->_local($message,$nick,$channel,$prompt,$cfg,$plan) if $plan;
    return $runtime->_ask($message,$nick,$channel,$prompt,$cfg);
}
sub note_rename {
    my ($bot,$old,$new,$ident,$host)=@_;my $runtime=$bot->{_meta_ai_runtime};return unless $runtime;
    my $from=join('!',fold($old),$ident//'',$host//'');
    my $to=join('!',fold($new),$ident//'',$host//'');
    eval {$_->rename_actor($from,$to) for values %{$runtime->{memories}}};
}
1;
