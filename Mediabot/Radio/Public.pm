package Mediabot::Radio::Public;
use strict;
use warnings;
use utf8;
use Digest::SHA qw(sha256_hex);
use Encode qw(encode_utf8 decode FB_CROAK);
use Fcntl qw(O_RDONLY O_NOFOLLOW S_ISREG);
use JSON::PP ();
use HTTP::Tiny;
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
        notice($ctx,"Syntaxe : $action ".($action eq 'play' ? '<lien YouTube>' : '<artiste ou titre>'),
                    "Syntax: $action ".($action eq 'play' ? '<YouTube URL>' : '<artist or title>')); return;
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
                my $title=$r->{title}//'';
                $title =~ s/[\x00-\x1f\x7f-\x9f]/ /g;
                $title=substr($title,0,160);
                notice($ctx,"Radio : ajouté à la file — $title","Radio: added to the queue — $title");
            } elsif (($r->{state}//'') eq 'uncertain' || !($r->{error} || ($r->{state}//'') eq 'failed')) {
                notice($ctx,'Radio : confirmation indisponible ; ne relance pas la demande tout de suite.',
                            'Radio: confirmation unavailable; do not repeat the request yet.');
            } else {
                my $code=$r->{error}//$r->{code}//'unavailable';
                my %messages=(
                    youtube_url_required=>['Utilise un lien YouTube https vers une seule vidéo.','Use an https YouTube link to one video.'],
                    no_playlists=>['Les playlists ne sont pas acceptées.','Playlists are not accepted.'],
                    no_matching_track=>['Aucun morceau trouvé en base pour cette recherche.','No catalogue track matches this search.'],
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
