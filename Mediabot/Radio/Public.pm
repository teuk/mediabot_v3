package Mediabot::Radio::Public;
use strict;
use warnings;
use utf8;
use Digest::SHA qw(sha256_hex);
use Encode qw(encode_utf8 decode FB_CROAK);
use Fcntl qw(O_RDONLY O_NOFOLLOW S_ISREG);
use JSON::PP ();
use HTTP::Tiny;
use Time::HiRes ();
use Mediabot::AsyncWorker;
use Mediabot::Helpers ();

sub fold { my $s=lc($_[0]//''); $s =~ tr/[]\\^/{}|~/; return $s }
sub setting {
    my ($bot,$key,$default)=@_;
    my $v=eval { $bot->{conf}->get('radio.'.$key) };
    return defined($v) && !ref($v) && length($v) ? $v : $default;
}
sub enabled {
    my ($ctx)=@_;
    return 0 if $ctx->is_private;
    return eval { Mediabot::Helpers::chanset_enabled($ctx->bot,$ctx->channel,'Radio',default=>0) } ? 1 : 0;
}
sub present {
    my ($ctx)=@_;
    my $bot=$ctx->bot;
    return 0 unless eval { $bot->{irc}->is_connected };
    my $own=eval { $bot->{irc}->nick_folded } // '';
    return 0 unless length $own;
    my @nicks;
    for my $channel (keys %{$bot->{hChannelsNicks}//{}}) {
        next unless fold($channel) eq fold($ctx->channel);
        my $list=$bot->{hChannelsNicks}{$channel};
        @nicks=@$list if ref($list) eq 'ARRAY';
    }
    my %members=map { fold($_)=>1 } @nicks;
    return $members{fold($ctx->nick)} && $members{fold($own)};
}
sub endpoint {
    my ($raw)=@_;
    die "endpoint" unless defined($raw) && length($raw)<=512 && $raw !~ /[\x00-\x20]/;
    die "endpoint" unless $raw =~ m{\A(https?)://([A-Za-z0-9][A-Za-z0-9.-]*)(?::([0-9]{1,5}))?(/[A-Za-z0-9_/-]*)?\z};
    my ($scheme,$host,$port)=($1,lc($2),$3);
    die "port" if defined($port) && ($port<1 || $port>65535);
    die "TLS required" unless $scheme eq 'https' || ($scheme eq 'http' && $host eq '127.0.0.1');
    $raw =~ s{/$}{};
    return $raw;
}
sub token {
    my ($path)=@_;
    die "token" unless defined($path) && $path =~ m{\A/} && $path !~ /[\r\n\0]/;
    sysopen(my $fh,$path,O_RDONLY|O_NOFOLLOW) or die "token";
    my @s=stat($fh);
    die "token permissions" unless S_ISREG($s[2]) && $s[3]==1 && $s[4]==$< && !($s[2]&077) && $s[7]<=128;
    local $/; my $value=<$fh>; close $fh;
    $value =~ s/\s+\z//;
    die "token format" unless $value =~ /\A[a-f0-9]{64}\z/;
    return $value;
}
sub call_api {
    my ($url,$secret,$method,$route,$payload)=@_;
    # No proxy inheritance and no redirects: the bearer token stays at this endpoint.
    my $http=HTTP::Tiny->new(timeout=>8,verify_SSL=>1,max_redirect=>0,max_size=>4096,
        proxy=>undef,http_proxy=>undef,https_proxy=>undef);
    my %options=(headers=>{'authorization'=>'Bearer '.$secret,'content-type'=>'application/json'});
    $options{content}=JSON::PP::encode_json($payload) if defined $payload;
    my $r=$http->request($method,$url.$route,\%options);
    my $value=eval { JSON::PP::decode_json($r->{content}//'') };
    return {error=>'api_unavailable'} unless ref($value) eq 'HASH';
    return $value if $r->{success};
    my $error={error=>$value->{error}//'api_unavailable'};
    $error->{retry_after}=int($value->{retry_after})
        if defined($value->{retry_after}) && !ref($value->{retry_after})
            && $value->{retry_after}=~/\A\d{1,3}\z/ && $value->{retry_after}>0;
    return $error;
}
sub notice {
    my ($ctx,$fr,$en)=@_;
    my $lang=eval { Mediabot::Helpers::channel_lang($ctx->bot,$ctx->channel) } // 'en';
    $ctx->reply_private($lang eq 'fr' ? $fr : $en);
}
sub queue_now { Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC()) }
sub safe_text {
    my ($value,$limit)=@_;
    return '' unless defined($value) && !ref($value);
    $value =~ s/[\p{Cc}\p{Cf}\p{Cs}]/ /g;
    $value =~ s/\s+/ /g;
    $value =~ s/^\s+|\s+$//g;
    my $bytes=encode_utf8($value);
    if (length($bytes)>$limit) {
        # Cut bytes once, then back up only over an incomplete UTF-8 character.
        # Re-encoding a large Icecast title for each removed character is quadratic.
        my $prefix=substr($bytes,0,$limit-3);
        while (length $prefix) {
            my $copy=$prefix;
            my $decoded=eval { decode('UTF-8',$copy,FB_CROAK) };
            return $decoded.'…' if defined $decoded;
            chop $prefix;
        }
        return '…';
    }
    return $value;
}
sub capsule {
    # Foreground accents only; the client's normal text stays readable on its
    # own light/dark theme. Never change song's existing presentation.
    my ($text,$red)=@_;
    return "\x0304\x02[ $text ]\x0F" if $red;
    return "\x0307\x02[ \x0F\x02$text\x0307 ]\x0F";
}
sub music_label {
    my ($value,$limit,$plain)=@_;
    $value=safe_text($value,$limit);
    $value =~ s/ — / - /;
    return "\x0F" . ($plain ? '' : "\x02") . $value . "\x0F";
}
sub language {
    my ($ctx)=@_;
    return (eval { Mediabot::Helpers::channel_lang($ctx->bot,$ctx->channel) } // 'en') eq 'fr' ? 'fr' : 'en';
}
sub queued_line {
    my ($r,$lang)=@_;
    my $rank=$r->{position};
    my $where=($r->{placement}//'') eq 'waiting' && defined($rank) && !ref($rank)
        && $rank =~ /\A[1-9]\d{0,2}\z/ && $rank<=512
        ? "#$rank"
        : ($r->{placement}//'') eq 'not_waiting'
            ? ($lang eq 'fr' ? 'plus en attente' : 'no longer waiting')
            : ($lang eq 'fr' ? 'rang non confirmé' : 'position unconfirmed');
    my $head=capsule(($lang eq 'fr' ? '+ FILE ' : '+ QUEUE ').$where,1).' ';
    my @details;
    my $seconds=$r->{duration_seconds};
    if (defined($seconds) && !ref($seconds) && $seconds =~ /\A[1-9][0-9]{0,3}\z/ && $seconds<=3600) {
        push @details,sprintf('%d:%02d',int($seconds/60),$seconds%60);
    }
    push @details,'MP3 #'.$r->{mp3}
        if defined($r->{mp3}) && !ref($r->{mp3}) && $r->{mp3} =~ /\A[1-9][0-9]{0,18}\z/;
    my $tail=@details ? ' · '.join(' · ',@details) : '';
    my $url=$r->{youtube_url};
    # Only the selected central identity can become a clickable replay link.
    # Default foreground and underline avoid dark-blue links on black themes.
    $tail.=" · \x1F$url\x0F" if defined($url) && !ref($url)
        && $url =~ m{\Ahttps://youtu\.be/[A-Za-z0-9_-]{11}\z};
    my $budget=360-length(encode_utf8($head.$tail))-4;
    return $head.music_label($r->{title} || ($lang eq 'fr' ? 'titre indisponible' : 'title unavailable'),$budget).$tail."\x0F";
}
sub public_or_notice {
    my ($ctx,$line,$kind,$private)=@_;
    my $bot=$ctx->bot;
    my $now=queue_now();
    my $map=$bot->{_radio_display_until} //= {};
    delete $map->{$_} for grep { ($map->{$_}{any}//0)<=$now && ($map->{$_}{queue}//0)<=$now } keys %$map;
    my $channel=fold($ctx->channel);
    my $entry=$map->{$channel}//{};
    # Shared by aliases and callers. Successful additions also leave a 15s gap.
    if (!$private && ($entry->{any}//0)<=$now && ($kind ne 'queue' || ($entry->{queue}//0)<=$now)
        && (exists($map->{$channel}) || keys(%$map)<128)) {
        $entry->{any}=$now+15;
        $entry->{queue}=$now+60 if $kind eq 'queue';
        $map->{$channel}=$entry;
        $ctx->reply($line);
    } else {
        $ctx->reply_private($line);
    }
}
sub consultation_allowed {
    my ($ctx)=@_;
    my $bot=$ctx->bot;
    my $now=queue_now();
    my $prefix=eval { $ctx->message->prefix } // '';
    return unless $prefix =~ /\A[^!\s]+!([^@\s]+\@[^\s]+)\z/;
    my $caller=sha256_hex(encode_utf8(lc($1)));
    my $map=$bot->{_radio_consult_until} //= {};
    delete $map->{$_} for grep {$map->{$_}<=$now} keys %$map;
    return if ($map->{$caller}//0)>$now || ($bot->{_radio_consult_global}//0)>$now || keys(%$map)>=256;
    $map->{$caller}=$now+5;
    $bot->{_radio_consult_global}=$now+1;
    return 1;
}
sub current_title {
    my ($bot)=@_;
    # Separate public Icecast read, without the radio API bearer token. One
    # bounded request in the child; missing status does not hide the queue.
    my $value=eval {
        my $base=endpoint(setting($bot,'RADIO_ICECAST_STATUS_BASE_URL','http://127.0.0.1:8000'));
        my $mount=setting($bot,'RADIO_ICECAST_PRIMARY_MOUNT','/radio.mp3');
        my $http=HTTP::Tiny->new(timeout=>2,verify_SSL=>1,max_redirect=>0,max_size=>262144,
            proxy=>undef,http_proxy=>undef,https_proxy=>undef);
        my $r=$http->get($base.'/status-json.xsl');
        die 'status' unless $r->{success};
        my $data=JSON::PP::decode_json($r->{content}//'');
        die 'status' unless ref($data) eq 'HASH' && ref($data->{icestats}) eq 'HASH';
        my $sources=$data->{icestats}{source};
        $sources=[$sources] if ref($sources) eq 'HASH';
        die 'status' unless ref($sources) eq 'ARRAY' && @$sources<=64;
        my @selected=grep { ref($_) eq 'HASH' && !ref($_->{listenurl})
            && (($_->{listenurl}//'') =~ m{\Ahttps?://[^/]+(/[^?#]*)\z}) && $1 eq $mount } @$sources;
        die 'mount' unless @selected==1;
        my $title=safe_text($selected[0]{title},240);
        my $artist=safe_text($selected[0]{artist},120);
        die 'title' unless length $title;
        $title="$artist - $title" if length($artist) && $title !~ /\A\Q$artist\E(?:\s+[-–—]\s+|\s*:\s+)/i;
        safe_text($title,240);
    };
    return $value;
}
sub queue_lines {
    my ($r,$command)=@_;
    return unless ref($r) eq 'HASH' && !exists($r->{error});
    for my $key (qw(protocol total preparing transferring)) {
        return unless defined($r->{$key}) && !ref($r->{$key}) && $r->{$key} =~ /\A\d{1,3}\z/;
    }
    return unless $r->{protocol} == 1 && $r->{total} <= 512
        && ref($r->{waiting}) eq 'ARRAY' && @{$r->{waiting}} == ($r->{total}>6 ? 6 : $r->{total});
    my @titles;
    for my $track (@{$r->{waiting}}) {
        return unless ref($track) eq 'HASH' && defined($track->{title}) && !ref($track->{title});
        push @titles,safe_text($track->{title},240);
    }
    my @pair;
    for my $lang (qw(fr en)) {
        my $unknown=$lang eq 'fr' ? 'titre indisponible' : 'title unavailable';
        if ($command eq 'nextsong') {
            push @pair,capsule($lang eq 'fr' ? 'À suivre' : 'Up next') . ' '
                . (@titles ? music_label($titles[0] || $unknown,240)
                    : ($lang eq 'fr' ? 'aucune demande en attente' : 'no waiting request'));
            next;
        }
        my $line;
        for (my $limit=180;$limit>=8;$limit--) {
            $line=capsule($lang eq 'fr' ? 'ANTENNE' : 'ON AIR',1) . ' '
                . music_label(safe_text($r->{on_air},240) || $unknown,$limit);
            if (@titles) {
                for my $i (0..($#titles<2 ? $#titles : 2)) {
                    $line.=' › '.capsule(''.($i+1)).' '.music_label($titles[$i] || $unknown,$limit,1);
                }
                $line.=' '.capsule('+'.($r->{total}-3)) if $r->{total}>3;
            } else {
                $line.=($lang eq 'fr' ? ' | file vide' : ' | queue empty');
            }
            my $pending=$r->{preparing}+$r->{transferring};
            $line.=($lang eq 'fr' ? " | préparation : $pending" : " | preparing: $pending") if $pending;
            last if length(encode_utf8($line))<=360;
        }
        push @pair,$line;
    }
    return [\@pair];
}
sub inspect_queue {
    my ($ctx,$command)=@_;
    return next_song($ctx) if $command eq 'nextsong';
    return unless $command =~ /\A(?:radioqueue|nextsong|queue)\z/ && enabled($ctx) && present($ctx);
    return unless consultation_allowed($ctx);
    my $bot=$ctx->bot;
    my $now=queue_now();
    if (@{$ctx->args}) { notice($ctx,"Syntaxe : $command","Syntax: $command"); return }
    unless (setting($bot,'RADIO_API_ENABLED','0') eq '1') {
        notice($ctx,'Radio : service non configuré.','Radio: service not configured.'); return;
    }
    if ($bot->{_radio_queue_pending} || ($bot->{_radio_queue_until}//0)>$now) {
        my $cache=$bot->{_radio_queue_cache};
        my $lines=ref($cache) eq 'HASH' && $cache->{until}>$now && $cache->{irc}==$bot->{irc}
            ? queue_lines($cache->{value},$command) : undef;
        if ($lines) { notice($ctx,@$_) for @$lines }
        else { notice($ctx,'Radio : consultation en cours ; patiente quelques secondes.',
                           'Radio: queue check in progress; wait a few seconds.') }
        return;
    }
    $bot->{_radio_queue_until}=$now+5;
    if (keys(%{$bot->{_radio_api_pending}//{}})>=4) {
        notice($ctx,'Radio : consultation occupée ; réessaie dans quelques secondes.',
                    'Radio: queue view busy; try again in a few seconds.'); return;
    }
    my ($url,$secret);
    unless (eval {
        $url=endpoint(setting($bot,'RADIO_API_URL','http://127.0.0.1:8765'));
        $secret=token(setting($bot,'RADIO_API_TOKEN_FILE','')); 1;
    }) {
        notice($ctx,'Radio : configuration API à vérifier.','Radio: check the API configuration.'); return;
    }
    my $irc=$bot->{irc};
    my $generation=eval { $bot->{wit_runtime_state}->capture_generation($ctx->channel) };
    $bot->{_radio_queue_pending}=1;
    my $worker=eval { Mediabot::AsyncWorker->start(
        loop=>(eval {$bot->getLoop} // $bot->{loop}),label=>'radio-queue',timeout=>12,max_output=>8192,
        child=>sub {
            my $r=call_api($url,$secret,'GET','/v1/queue',undef);
            $r->{on_air}=current_title($bot) if ref($r) eq 'HASH' && !$r->{error};
            return $r;
        },
        on_done=>sub {
            my ($result)=@_;
            delete $bot->{_radio_queue_pending};
            return unless enabled($ctx) && present($ctx) && $bot->{irc}==$irc
                && defined($generation) && $generation == (eval { $bot->{wit_runtime_state}->capture_generation($ctx->channel) } // -1);
            my $lines=queue_lines($result->{value},$command);
            unless ($lines) {
                delete $bot->{_radio_queue_cache};
                notice($ctx,'Radio : file commune indisponible ; réessaie dans quelques secondes.',
                            'Radio: shared queue unavailable; try again in a few seconds.'); return;
            }
            $bot->{_radio_queue_cache}={value=>$result->{value},until=>queue_now()+5,irc=>$irc};
            my $line=$lines->[0][language($ctx) eq 'fr' ? 0 : 1];
            public_or_notice($ctx,$line,'queue',$command eq 'nextsong');
        }) };
    unless ($worker) {
        delete $bot->{_radio_queue_pending};
        notice($ctx,'Radio : consultation indisponible ; réessaie dans quelques secondes.',
                    'Radio: queue view unavailable; try again in a few seconds.'); return;
    }
    $bot->{_radio_queue_pending}=$worker if exists $bot->{_radio_queue_pending};
    return 1;
}
sub next_song {
    my ($ctx)=@_;
    return unless enabled($ctx) && present($ctx);
    return unless $ctx->require_level('Administrator');
    if (@{$ctx->args}) { notice($ctx,'Syntaxe : nextsong','Syntax: nextsong'); return }
    return unless consultation_allowed($ctx);
    my $bot=$ctx->bot;
    if ($bot->{_radio_next_pending}) {
        notice($ctx,'Radio : passage au suivant déjà en cours.','Radio: a transition is already in progress.'); return;
    }
    my ($url,$secret,$id,$caller);
    unless (eval {
        die 'disabled' unless setting($bot,'RADIO_API_ENABLED','0') eq '1';
        my $prefix=$ctx->message->prefix;
        die 'identity' unless $prefix =~ /\A([^!\s]+)!([^@\s]+\@[^\s]+)\z/ && fold($1) eq fold($ctx->nick);
        $caller=sha256_hex(encode_utf8(lc($2)));
        $url=endpoint(setting($bot,'RADIO_API_URL','http://127.0.0.1:8765'));
        $secret=token(setting($bot,'RADIO_API_TOKEN_FILE',''));
        open(my $random,'<:raw','/dev/urandom') or die 'random';
        read($random,my $bytes,16)==16 or die 'random'; close $random;
        $id=unpack('H*',$bytes); 1;
    }) { notice($ctx,'Radio : configuration API à vérifier.','Radio: check the API configuration.'); return }
    my $irc=$bot->{irc};
    my $generation=eval { $bot->{wit_runtime_state}->capture_generation($ctx->channel) };
    $bot->{_radio_next_pending}=1;
    my $worker=eval { Mediabot::AsyncWorker->start(
        loop=>(eval {$bot->getLoop} // $bot->{loop}),label=>'radio-next',timeout=>12,max_output=>8192,
        child=>sub {
            # Never send a second skip after an ambiguous response. The server
            # also persists an idempotent receipt before touching the player.
            call_api($url,$secret,'POST','/v1/next',{id=>$id,caller=>$caller,channel=>fold($ctx->channel)});
        },
        on_done=>sub {
            my ($result)=@_;
            delete $bot->{_radio_next_pending};
            return unless enabled($ctx) && present($ctx) && $bot->{irc}==$irc
                && defined($generation) && $generation == (eval { $bot->{wit_runtime_state}->capture_generation($ctx->channel) } // -1);
            # Resolve the current identity again before publishing admin feedback.
            my $user=eval { $bot->get_user_from_message($ctx->message) };
            return unless $user && $user->is_authenticated && $user->has_level('Administrator');
            my $r=ref($result->{value}) eq 'HASH' ? $result->{value} : {};
            if (($r->{state}//'') eq 'completed' && ($r->{origin}//'') =~ /\A(?:queue|playlist|live)\z/) {
                delete $bot->{_radio_queue_cache};
                my $fr=language($ctx) eq 'fr';
                my $kind=$r->{origin} eq 'queue' ? ($fr ? 'file' : 'queue')
                    : $r->{origin} eq 'live' ? 'live' : ($fr ? 'playlist globale' : 'global playlist');
                my $line=capsule('Next · '.$kind).' '.music_label($r->{title} || ($fr ? 'titre indisponible' : 'title unavailable'),240);
                public_or_notice($ctx,$line,'success',0);
            } else {
                my $code=$r->{error}//$r->{code}//'';
                my %errors=(
                    next_live=>['Le direct est prioritaire ; aucun morceau sauté.','Live input has priority; nothing was skipped.'],
                    next_unavailable=>['Contrôle du suivant indisponible côté radio.','Next-track control is unavailable on the radio server.'],
                    next_changed=>['La piste a changé entre-temps ; aucun second saut demandé.','The track changed in the meantime; no second skip was requested.'],
                    next_busy=>['Patiente quelques secondes avant un autre passage au suivant.','Wait a few seconds before skipping again.']);
                my $m=$errors{$code} // ['Passage au suivant non confirmé ; ne relance pas immédiatement.',
                    'Track transition not confirmed; do not repeat immediately.'];
                notice($ctx,'Radio : '.$m->[0],'Radio: '.$m->[1]);
            }
        }) };
    delete $bot->{_radio_next_pending} unless $worker;
    notice($ctx,'Radio : commande indisponible.','Radio: command unavailable.') unless $worker;
    return $worker ? 1 : 0;
}
sub delete_track {
    my ($ctx)=@_;
    return unless enabled($ctx) && present($ctx);
    return unless $ctx->require_level('Master');
    my $args=$ctx->args;
    unless (@$args==1 && defined($args->[0]) && !ref($args->[0]) && $args->[0] =~ /\A[1-9][0-9]{0,18}\z/) {
        notice($ctx,'Syntaxe : deltrack <id_mp3 central>','Syntax: deltrack <central id_mp3>'); return;
    }
    return unless consultation_allowed($ctx);
    my $bot=$ctx->bot;
    if ($bot->{_radio_delete_pending}) {
        notice($ctx,'Radio : retrait déjà en cours.','Radio: a withdrawal is already in progress.'); return;
    }
    my ($url,$secret,$id,$caller);
    unless (eval {
        die 'disabled' unless setting($bot,'RADIO_API_ENABLED','0') eq '1';
        my $prefix=$ctx->message->prefix;
        die 'identity' unless $prefix =~ /\A([^!\s]+)!([^@\s]+\@[^\s]+)\z/ && fold($1) eq fold($ctx->nick);
        $caller=sha256_hex(encode_utf8(lc($2)));
        $url=endpoint(setting($bot,'RADIO_API_URL','http://127.0.0.1:8765'));
        $secret=token(setting($bot,'RADIO_API_TOKEN_FILE',''));
        open(my $random,'<:raw','/dev/urandom') or die 'random';
        read($random,my $bytes,16)==16 or die 'random'; close $random;
        $id=unpack('H*',$bytes); 1;
    }) { notice($ctx,'Radio : configuration API à vérifier.','Radio: check the API configuration.'); return }
    my $mp3=$args->[0];
    my $irc=$bot->{irc};
    my $generation=eval { $bot->{wit_runtime_state}->capture_generation($ctx->channel) };
    $bot->{_radio_delete_pending}=1;
    my $worker=eval { Mediabot::AsyncWorker->start(
        loop=>(eval {$bot->getLoop} // $bot->{loop}),label=>'radio-deltrack',timeout=>12,max_output=>8192,
        child=>sub {
            call_api($url,$secret,'POST','/v1/tracks/remove',
                {id=>$id,caller=>$caller,channel=>fold($ctx->channel),mp3=>"$mp3"});
        },
        on_done=>sub {
            my ($result)=@_;
            delete $bot->{_radio_delete_pending};
            return unless enabled($ctx) && present($ctx) && $bot->{irc}==$irc
                && defined($generation) && $generation == (eval { $bot->{wit_runtime_state}->capture_generation($ctx->channel) } // -1);
            my $user=eval { $bot->get_user_from_message($ctx->message) };
            return unless $user && $user->is_authenticated && $user->has_level('Master');
            my $r=ref($result->{value}) eq 'HASH' ? $result->{value} : {};
            if (($r->{state}//'') eq 'removed' && ($r->{mp3}//'') eq "$mp3") {
                my $title=music_label($r->{title},180);
                notice($ctx,capsule("MP3 #$mp3 retiré et bloqué").' '.$title.' — Les lectures déjà programmées continuent ; nextsong pour passer.',
                    capsule("MP3 #$mp3 removed and blocked").' '.$title.' — Already scheduled playback continues; nextsong skips it.');
            } else {
                my %errors=(
                    track_not_found=>['ID absent du catalogue central.','ID not found in the central catalogue.'],
                    catalogue_busy=>['Un morceau est en préparation ; réessaie le retrait dans quelques secondes.',
                        'A track is being prepared; retry the withdrawal in a few seconds.'],
                    catalogue_changed=>['La ligne a changé ; retrait interrompu, contrôle côté radio nécessaire.',
                        'The row has changed; withdrawal stopped, radio operator review required.']);
                my $m=$errors{$r->{error}//''} // ['Retrait non confirmé ; vérifie ou relance deltrack avec le même ID.',
                    'Withdrawal not confirmed; check or retry deltrack with the same ID.'];
                notice($ctx,'Radio : '.$m->[0],'Radio: '.$m->[1]);
            }
        }) };
    delete $bot->{_radio_delete_pending} unless $worker;
    notice($ctx,'Radio : commande indisponible.','Radio: command unavailable.') unless $worker;
    return $worker ? 1 : 0;
}
sub submit {
    my ($ctx,$action)=@_;
    return unless enabled($ctx) && present($ctx);
    my $bot=$ctx->bot;
    unless (setting($bot,'RADIO_API_ENABLED','0') eq '1') {
        notice($ctx,'Radio : service non configuré.','Radio: service not configured.'); return;
    }
    my $query=join(' ',@{$ctx->args});
    if (!utf8::is_utf8($query) && $query =~ /[^\x00-\x7f]/) {
        my $decoded=eval { decode('UTF-8',$query,FB_CROAK) };
        $query=$decoded if defined $decoded;
    }
    $query =~ s/^\s+|\s+$//g;
    unless (length($query) && length($query)<=255 && $query !~ /[\x00-\x1f]/) {
        notice($ctx,"Syntaxe : $action ".($action eq 'play' ? '<artiste titre ou lien YouTube>' : '<pattern artiste ou titre>'),
                    "Syntax: $action ".($action eq 'play' ? '<artist title or YouTube URL>' : '<artist or title pattern>')); return;
    }
    my $prefix=eval { $ctx->message->prefix } // '';
    return unless $prefix =~ /\A([^!\s]+)!([^@\s]+\@[^\s]+)\z/ && fold($1) eq fold($ctx->nick);
    my $caller=sha256_hex(encode_utf8(lc($2)));
    my $pending=$bot->{_radio_api_pending} //= {};
    if ($pending->{$caller} || keys(%$pending)>=4) {
        notice($ctx,'Radio : une demande est déjà en cours ; patiente un peu.',
                    'Radio: a request is already pending; please wait.'); return;
    }
    my ($url,$secret,$id);
    my $ready=eval {
        $url=endpoint(setting($bot,'RADIO_API_URL','http://127.0.0.1:8765'));
        $secret=token(setting($bot,'RADIO_API_TOKEN_FILE',''));
        open(my $random,'<:raw','/dev/urandom') or die "random";
        read($random,my $bytes,16)==16 or die "random"; close $random;
        $id=unpack('H*',$bytes); 1;
    };
    unless ($ready) { notice($ctx,'Radio : configuration API à vérifier.','Radio: check the API configuration.'); return }
    my $loop=eval { $bot->getLoop } // $bot->{loop};
    my $irc=$bot->{irc};
    my $generation=eval { $bot->{wit_runtime_state}->capture_generation($ctx->channel) };
    my $valid=sub { enabled($ctx) && present($ctx) && $bot->{irc}==$irc
                    && defined($generation) && $generation == (eval { $bot->{wit_runtime_state}->capture_generation($ctx->channel) } // -1) };
    my $body={id=>$id,caller=>$caller,channel=>fold($ctx->channel),action=>$action,query=>$query};
    $pending->{$caller}=1;
    my $worker=Mediabot::AsyncWorker->start(loop=>$loop,label=>'radio-api',timeout=>2000,max_output=>16384,
        child=>sub {
            my ($emit)=@_;
            my $r=call_api($url,$secret,'POST','/v1/requests',$body);
            # Same ID on transport retry, so a lost HTTP response cannot duplicate a download.
            $r=call_api($url,$secret,'POST','/v1/requests',$body) if ($r->{error}//'') eq 'api_unavailable';
            return $r if $r->{error};
            $emit->({accepted=>1}) unless ($r->{state}//'') =~ /\A(?:queued|failed|uncertain)\z/;
            my $deadline=time+1900;
            while (time<$deadline && ($r->{state}//'') !~ /\A(?:queued|failed|uncertain)\z/) {
                sleep 5;
                my $next=call_api($url,$secret,'GET','/v1/requests/'.$id,undef);
                $r=$next unless $next->{error};
            }
            return $r;
        },
        on_progress=>sub {
            return unless $valid->();
            notice($ctx,'Radio : demande reçue, préparation en cours.','Radio: request received, preparing track.');
        },
        on_done=>sub {
            my ($result)=@_;
            delete $pending->{$caller};
            return unless $valid->();
            my $r=ref($result->{value}) eq 'HASH' ? $result->{value} : {};
            if (($r->{state}//'') eq 'queued') {
                delete $bot->{_radio_queue_cache};
                public_or_notice($ctx,queued_line($r,language($ctx)),'success',0);
            } elsif (($r->{state}//'') eq 'uncertain' || !($r->{error} || ($r->{state}//'') eq 'failed')) {
                notice($ctx,'Radio : confirmation indisponible ; ne relance pas la demande tout de suite.',
                            'Radio: confirmation unavailable; do not repeat the request yet.');
            } else {
                my $code=$r->{error}//$r->{code}//'unavailable';
                my %messages=(
                    track_removed=>['Ce morceau a été retiré et bloqué par un Master.','This track was removed and blocked by a Master.'],
                    youtube_url_required=>['Utilise un lien YouTube https vers une seule vidéo.','Use an https YouTube link to one video.'],
                    no_playlists=>['Les playlists ne sont pas acceptées.','Playlists are not accepted.'],
                    no_matching_track=>['Aucun morceau trouvé en base pour cette recherche.','No catalogue track matches this search.'],
                    no_youtube_match=>['Aucune vidéo adaptée trouvée ; précise artiste et titre ou donne un lien YouTube.',
                        'No suitable video found; refine the artist and title or provide a YouTube URL.'],
                    youtube_search_failed=>['Recherche YouTube indisponible ; consulte les diagnostics radio.',
                        'YouTube search is unavailable; check the radio diagnostics.'],
                    catalogue_tracks_unavailable=>['Morceau trouvé en base, mais fichier audio indisponible ; vérification côté radio nécessaire.',
                        'Track found in the catalogue, but its audio file is unavailable; the radio operator needs to check it.'],
                    catalogue_scan_timeout=>['La vérification du catalogue prend trop longtemps ; contrôle côté radio nécessaire.',
                        'Catalogue validation took too long; the radio operator needs to check it.'],
                    youtube_auth_required=>['YouTube refuse la session ; renouvellement des cookies nécessaire côté radio.',
                        'YouTube rejected the session; the radio operator needs to refresh its cookies.'],
                    youtube_rate_limited=>['YouTube limite les téléchargements ; pause temporaire côté radio.',
                        'YouTube is rate-limiting downloads; the radio service is pausing downloads.'],
                    youtube_paused=>['Téléchargements YouTube temporairement suspendus ; les morceaux déjà en base restent utilisables.',
                        'YouTube downloads are temporarily paused; existing catalogue tracks remain available.'],
                    youtube_unavailable=>['Cette vidéo est indisponible pour la radio.',
                        'This video is unavailable to the radio service.'],
                    youtube_no_data=>['YouTube ne fournit pas les données audio ; vérification côté radio nécessaire.',
                        'YouTube supplied no audio data; the radio operator needs to check it.'],
                    download_failed=>['Échec du téléchargement ; consulte les diagnostics radio.',
                        'Download failed; check the radio diagnostics.'],
                    cookies_unavailable=>['Le fichier de cookies nécessite une vérification côté radio.',
                        'The radio operator needs to check its cookie file.'],
                    storage_full=>['Espace disque insuffisant côté radio ; téléchargement suspendu.',
                        'Insufficient radio storage space; download stopped.'],
                    cached_audio_changed=>['Le fichier audio en cache a changé ; contrôle côté radio nécessaire.',
                        'The cached audio file has changed; the radio operator needs to check it.'],
                    duplicate_track=>['Ce morceau est déjà demandé ou vient de passer dans la file.',
                        'This track is already requested or was recently queued.'],
                    request_pending=>['Ta demande précédente est encore en préparation.','Your previous request is still being prepared.'],
                    duplicate_video=>['Ce morceau est déjà demandé ou vient de passer dans la file.','This track is already requested or was recently queued.']);
                my $m=$messages{$code};
                if ($code =~ /\A(?:caller_cooldown|channel_cooldown)\z/) {
                    my $wait=$r->{retry_after};
                    $m=defined($wait) && $wait=~/\A\d{1,3}\z/ && $wait>0
                        ? ["Patiente encore $wait s avant une nouvelle demande.","Wait another $wait s before a new request."]
                        : ['Patiente un peu avant une nouvelle demande.','Please wait before making another request.'];
                }
                $m=['La file est pleine ; réessaie plus tard.','The queue is full; try again later.'] if $code =~ /queue_full/;
                $m //= ['La demande a échoué ; consulte les diagnostics radio.','Request failed; check the radio diagnostics.'];
                notice($ctx,'Radio : '.$m->[0],'Radio: '.$m->[1]);
            }
        });
    $pending->{$caller}=$worker if $worker && exists $pending->{$caller};
    return $worker ? 1 : 0;
}
1;
