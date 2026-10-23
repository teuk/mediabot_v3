package Mediabot::External::AppleMusicFallback;

use strict;
use warnings;
use utf8;
use feature 'fc';
use Unicode::Normalize qw(NFKC);
use JSON::PP ();
use Scalar::Util qw(refaddr);
use Mediabot::JSON qw(decode_json_payload);
use Mediabot::AsyncWorker ();
use Mediabot::IRC::DeliveryContext qw(capture_delivery_context delivery_context_current);
use Mediabot::IRC::TextBudget qw(_irc_wire_bytes _irc_prefix_for_budget);

# Opt-in, read-only at runtime. Missing catalogue rows and SQL errors mean off.
sub enabled {
    my ($bot,$channel)=@_;
    return 0 unless defined($channel) && !ref($channel) && $channel =~ /\A#[^\x00-\x20\x7f,:]{1,254}\z/;
    my $on=eval {
        my $dbh=$bot->{db} ? $bot->{db}->ensure_connected : $bot->{dbh};
        return 0 unless $dbh;
        my $sth=$dbh->prepare(q{SELECT CS.id_channel_set FROM CHANNEL_SET CS
            JOIN CHANNEL C ON C.id_channel=CS.id_channel
            JOIN CHANSET_LIST CL ON CL.id_chanset_list=CS.id_chanset_list
            WHERE C.name=? AND CL.chanset=?}) or return 0;
        my $ok=$sth->execute($channel,'AppleMusicFallback');
        my $row=$ok ? $sth->fetchrow_arrayref : undef;
        my $error=$sth->err; $sth->finish;
        return $ok && !$error && $row ? 1 : 0;
    };
    return $on ? 1 : 0;
}

# Called only by an already-authorized explicit chanset +AppleMusicFallback.
# This adds catalogue DATA in the existing tables; there is no schema change.
sub register_chanset {
    my ($bot)=@_;
    my $dbh=$bot->{dbh} or return;
    return eval {
        my $sth=$dbh->prepare(q{INSERT INTO CHANSET_LIST(chanset)
            SELECT ? WHERE NOT EXISTS(SELECT 1 FROM CHANSET_LIST WHERE chanset=?)}) or return;
        my $ok=$sth->execute('AppleMusicFallback','AppleMusicFallback');
        $sth->finish;
        return $ok ? 1 : undef;
    };
}

sub epoch { return $_[0]{_applemusic_fallback_epoch}{lc($_[1])}//0 }
sub note_policy_change { return ++$_[0]{_applemusic_fallback_epoch}{lc($_[1])} }
sub _text {
    my ($s,$max)=@_;
    return unless defined($s) && !ref($s) && length($s)<=$max && $s !~ /[\x00-\x1f\x7f-\x9f]/;
    $s =~ s/\s+/ /g; $s =~ s/^\s+|\s+$//g;
    return length($s) ? $s : undef;
}
sub _norm {
    my ($s)=@_; $s=fc(NFKC($s//''));
    $s =~ s/[^\p{L}\p{N}\p{M}]+/ /g;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}
sub _seconds {
    my ($s)=@_; return unless defined($s) && !ref($s);
    return 3600*$1+60*$2+$3 if $s =~ /\A([0-9]{1,3})h([0-5][0-9])m([0-5][0-9])s\z/;
    return 60*$1+$2 if $s =~ /\A([0-9]{1,4})m ([0-5][0-9])s\z/;
    return;
}
sub record {
    my ($fetch,$info)=@_;
    return unless ref($fetch) eq 'HASH' && defined($fetch->{source}) && !ref($fetch->{source}) && $fetch->{source} eq 'itunes-lookup'
        && ref($info) eq 'HASH' && defined($info->{track_id}) && !ref($info->{track_id})
        && $info->{track_id} =~ /\A[0-9]{1,20}\z/ && ref($fetch->{details}) eq 'HASH';
    my $title=_text($fetch->{title},200); my $artist=_text($fetch->{details}{artist},160);
    my $seconds=_seconds($fetch->{details}{duration});
    return unless defined($title) && defined($artist) && length(_norm($title)) && length(_norm($artist)) && $seconds && $seconds<=86400;
    return unless defined($info->{storefront}) && !ref($info->{storefront}) && $info->{storefront} =~ /\A[a-z]{2}\z/;
    return {title=>$title,artist=>$artist,seconds=>$seconds,
        key=>join(':',$info->{storefront}//'us',$info->{track_id},_norm($artist),_norm($title),$seconds)};
}
# Recheck the in-memory/worker boundary; never stringify unexpected leaves.
sub _record_copy {
    my ($r)=@_;return unless ref($r) eq 'HASH';
    my $title=_text($r->{title},200);my $artist=_text($r->{artist},160);
    return unless defined($title) && defined($artist) && length(_norm($title)) && length(_norm($artist))
        && defined($r->{seconds}) && !ref($r->{seconds}) && $r->{seconds} =~ /\A[0-9]{1,5}\z/
        && $r->{seconds}>0 && $r->{seconds}<=86400
        && defined($r->{key}) && !ref($r->{key}) && length($r->{key}) && length($r->{key})<=1024;
    return {title=>$title,artist=>$artist,seconds=>0+$r->{seconds},key=>$r->{key}};
}
sub _http {
    require HTTP::Tiny;
    return HTTP::Tiny->new(timeout=>$_[0],verify_SSL=>1,max_size=>512*1024,max_redirect=>0);
}
sub _config {
    my ($bot,$key)=@_; my $v=eval {$bot->{conf}->get($key)};
    return defined($v) && !ref($v) ? $v : '';
}
sub prerequisites {
    my ($bot)=@_;
    return {tavily=>length(_config($bot,'tavily.API_KEY'))?1:0,
        youtube=>length(_config($bot,'main.YOUTUBE_APIKEY'))?1:0};
}
sub _url {
    my ($platform,$url)=@_; return unless defined($url) && !ref($url) && length($url)<=2048;
    if ($platform eq 'spotify' && $url =~ m{\Ahttps://open\.spotify\.com/(?:intl-[a-z]{2}/)?track/([A-Za-z0-9]{22})(?:[?#][^\x00-\x20\x7f]*)?\z}i) {
        return ('https://open.spotify.com/track/'.$1,$1);
    }
    if ($platform eq 'youtube') {
        require Mediabot::External::YouTube;
        my $id=Mediabot::External::YouTube::_is_youtube_url($url);
        return ('https://www.youtube.com/watch?v='.$id,$id) if $id;
    }
    return;
}
sub _search {
    my ($bot,$r,$platform)=@_;
    my $key=_config($bot,'tavily.API_KEY'); return [] unless length $key;
    # Authorization never follows redirects. Search text is data, not a URL.
    my $http=_http(6);
    my $res=eval {$http->request('POST','https://api.tavily.com/search',{
        headers=>{Authorization=>'Bearer '.$key,'Content-Type'=>'application/json'},
        content=>JSON::PP->new->utf8->encode({query=>qq{"$r->{artist}" "$r->{title}"},
            topic=>'general',search_depth=>'basic',max_results=>3,
            include_domains=>[$platform eq 'spotify'?'open.spotify.com':'youtube.com'],
            include_domains_mode=>'restrict',include_answer=>JSON::PP::false,
            include_raw_content=>JSON::PP::false})})};
    return [] unless ref($res) eq 'HASH' && $res->{success};
    my $data=eval {decode_json_payload($res->{content})};
    return [] unless ref($data) eq 'HASH' && ref($data->{results}) eq 'ARRAY';
    my (@out,%seen);
    for my $row (@{$data->{results}}) {
        next unless ref($row) eq 'HASH';
        my ($url,$id)=_url($platform,$row->{url}); next unless $url && !$seen{$id}++;
        push @out,{url=>$url,id=>$id}; last if @out==3;
    }
    return \@out;
}
sub fetch {
    my ($bot,$r,$platform)=@_;
    $r=_record_copy($r);
    return [] unless $r && defined($platform) && !ref($platform) && ($platform eq 'spotify' || $platform eq 'youtube');
    return [] if $platform eq 'youtube' && !length(_config($bot,'main.YOUTUBE_APIKEY'));
    my $candidates=_search($bot,$r,$platform); return [] unless @$candidates;
    if ($platform eq 'spotify') {
        require Mediabot::External::Spotify;
        my $count=0;
        for my $c (@$candidates) {
            last if $count++==2;
            my $m=eval {Mediabot::External::Spotify::_spotify_fetch_sync($bot,$c->{url},'track',$c->{id})};
            next unless ref($m) eq 'HASH' && defined(_text($m->{title},240)) && defined(_text($m->{artist},240));
            my $seconds=_seconds($m->{duration});
            return [$c->{url}] if defined($seconds) && abs($seconds-$r->{seconds})<=3
                && _norm($m->{title}) eq _norm($r->{title}) && _norm($m->{artist}) eq _norm($r->{artist});
        }
        return [];
    }
    my $key=_config($bot,'main.YOUTUBE_APIKEY'); return [] unless length $key;
    require URI::Escape;
    require Mediabot::External::YouTube;
    my $ids=[map {$_->{id}} @$candidates];
    my $url='https://www.googleapis.com/youtube/v3/videos?id='.join(',',@$ids)
        .'&key='.URI::Escape::uri_escape_utf8($key)
        .'&part=snippet,contentDetails,statistics'
        .'&fields=items(id,snippet/title,snippet/channelTitle,contentDetails/duration,statistics/viewCount)';
    my $http=_http(10);
    my $res=eval {$http->get($url)};
    return [] unless ref($res) eq 'HASH' && $res->{success};
    my $by_id=Mediabot::External::YouTube::_youtube_search_parse_videos($res->{content},$ids);
    my @matches;
    for my $c (@$candidates) {
        my $m=$by_id->{$c->{id}};next unless ref($m) eq 'HASH' && defined(_text($m->{title},400)) && defined(_text($m->{channel_title},240));
        next unless $m->{duration} =~ /\APT(?:([0-9]{1,2})H)?(?:([0-9]{1,2})M)?(?:([0-9]{1,2})S)?\z/;
        my $seconds=3600*($1//0)+60*($2//0)+($3//0);next if abs($seconds-$r->{seconds})>3;
        my $title=$m->{title};
        $title =~ s/\s*[\[(](?:official\s+audio|audio)[\])]\s*\z//i;
        my ($t,$a,$want)=(_norm($title),_norm($r->{artist}),_norm($r->{title}));
        my $channel=_norm($m->{channel_title});
        next unless $t eq "$a $want" || $t eq "$want $a"
            || ($t eq $want && ($channel eq $a || $channel eq "$a topic" || $channel eq $a.'vevo'));
        push @matches,[$channel eq "$a topic"?0:1,$c->{url}];
    }
    @matches=sort {$a->[0]<=>$b->[0]} @matches;
    return @matches ? [$matches[0][1]] : [];
}
sub line {
    my ($platform,$nick,$r,$url)=@_;
    $r=_record_copy($r);return unless $r && defined($platform) && !ref($platform);
    my ($safe)=_url($platform,$url);return unless $safe;
    my $badge;
    if ($platform eq 'spotify') {require Mediabot::External::Spotify;$badge=Mediabot::External::Spotify::_spotify_badge()}
    else {require Mediabot::External::YouTube;$badge=Mediabot::External::YouTube::_yt_label()}
    $nick=_text($nick,80)//'';
    my $head="($nick) $badge\x0f ";my $tail=" · $safe\x0f";
    my $text=_text($r->{artist},160).' — '._text($r->{title},200);
    utf8::upgrade($head);utf8::upgrade($tail);
    # Only badges have a fixed background; text/URLs use the client's theme.
    my $budget=400-_irc_wire_bytes($head.$tail);
    return unless $budget>10;
    $text=_irc_prefix_for_budget($text,$budget);
    return $head.$text.$tail;
}
sub start {
    my ($bot,$nick,$channel,$r,$binding,$submitted_epoch)=@_;
    $r=_record_copy($r);
    return 0 unless $r && enabled($bot,$channel);
    $binding ||= capture_delivery_context($bot,$channel);
    $submitted_epoch //= epoch($bot,$channel);
    my $current=sub {delivery_context_current($bot,$binding)
        && epoch($bot,$channel)==$submitted_epoch && enabled($bot,$channel)
        && eval {Mediabot::External::_chanset_ok($bot,$channel,'AppleMusic')}};
    return 0 unless $current->();
    my $loop=eval {$bot->getLoop};$loop||=$bot->{loop};
    return 0 unless $loop && eval {$loop->can('watch_process') && $loop->can('add') && $loop->can('remove')};
    my $s=$bot->{_applemusic_fallback} ||= {cache=>{},pending=>{},recent=>{},starts=>[]};
    my $now=time;
    delete $s->{cache}{$_} for grep {$s->{cache}{$_}{until}<=$now} keys %{$s->{cache}};
    delete $s->{recent}{$_} for grep {$s->{recent}{$_}<=$now-30} keys %{$s->{recent}};
    my $config=prerequisites($bot);return 0 unless $config->{tavily};
    my $request_key=lc($channel)."\0".$r->{key};
    return 0 if exists $s->{recent}{$request_key} || keys(%{$s->{recent}})>=256;
    $s->{recent}{$request_key}=$now;
    for my $platform (qw(spotify youtube)) {
        next if $platform eq 'youtube' && !$config->{youtube};
        my $key=$platform."\0".$r->{key};
        my $send=sub {
            my ($urls)=@_;return unless $current->() && ref($urls) eq 'ARRAY' && @$urls==1;
            my $text=line($platform,$nick,$r,$urls->[0]);return unless defined $text;
            Mediabot::Helpers::botPrivmsg($bot,$channel,$text,{no_defer=>1});
        };
        if (my $cache=$s->{cache}{$key}) {$send->($cache->{urls});next}
        # Share a lookup across channels, retaining each independently bound recipient.
        if (my $pending=$s->{pending}{$key}) {push @{$pending->{send}},$send if @{$pending->{send}}<16;next}
        @{$s->{starts}}=grep {$_>$now-60} @{$s->{starts}};
        next if keys(%{$s->{pending}})>=4 || @{$s->{starts}}>=12;
        push @{$s->{starts}},$now;
        my $attempt={send=>[$send]};$s->{pending}{$key}=$attempt;
        my $done=0;
        my $complete=sub {
            my ($result)=@_;return if $done++;
            return unless $s->{pending}{$key} && refaddr($s->{pending}{$key})==refaddr($attempt);
            delete $s->{pending}{$key};
            my $urls=ref($result) eq 'HASH' && $result->{ok} && ref($result->{value}) eq 'ARRAY' ? $result->{value}:[];
            my ($safe)=@$urls==1 ? _url($platform,$urls->[0]) : ();
            $urls=$safe ? [$safe]:[];
            $s->{cache}{$key}={until=>time+($safe?3600:120),urls=>$urls};
            while (keys(%{$s->{cache}})>128) {my ($old)=sort {$s->{cache}{$a}{until}<=>$s->{cache}{$b}{until}} keys %{$s->{cache}};delete $s->{cache}{$old}}
            for my $recipient (@{$attempt->{send}}) {eval {$recipient->($urls)}}
            $attempt->{send}=[];
        };
        my $worker=eval {Mediabot::AsyncWorker->start(loop=>$loop,label=>'AppleMusic '.$platform.' fallback',
            timeout=>$platform eq 'spotify'?35:20,max_output=>4096,
            child=>sub {
                # These children perform only HTTP. Never DESTROY an inherited DB connection.
                eval {$bot->{dbh}{InactiveDestroy}=1 if $bot->{dbh}};
                eval {$bot->{db}{dbh}{InactiveDestroy}=1 if $bot->{db} && $bot->{db}{dbh}};
                return fetch($bot,$r,$platform);
            },on_done=>$complete)};
        $complete->({ok=>0}) unless $worker || $done;
    }
    return 1;
}
1;
