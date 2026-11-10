package Mediabot::External::TikTok;
use strict;
use warnings;
use utf8;
use URI ();
use URI::Escape qw(uri_escape_utf8);
use HTML::Entities qw(decode_entities);
use JSON::PP ();
use HTTP::Tiny ();
use Scalar::Util qw(refaddr);
use Mediabot::AsyncWorker ();
use Mediabot::IRC::Text qw(decode_irc_text);
use Mediabot::IRC::TextBudget qw(_irc_wire_bytes _irc_prefix_for_budget);
use Mediabot::IRC::DeliveryContext qw(capture_delivery_context delivery_context_current);

sub is_tiktok_url {
    my ($url) = @_;
    return 0 unless defined($url) && !ref($url) && length($url) <= 2048;
    my $u = eval { URI->new($url) };
    return 0 unless $u && ($u->scheme // '') =~ /\Ahttps?\z/i;
    my $host = eval { lc($u->host // '') } // '';
    return $host =~ /\A(?:[a-z0-9-]+\.)*tiktok\.com\.?\z/ ? 1 : 0;
}

sub url_info {
    my ($url) = @_;
    return unless is_tiktok_url($url) && $url !~ /[\x00-\x20\x7f\\]/;
    my $u = URI->new($url);
    return if defined $u->userinfo;
    my $port = $u->port;
    return unless defined($port) && $port =~ /\A[0-9]{1,5}\z/
        && $port == (lc($u->scheme) eq 'https' ? 443 : 80);
    my $host = lc($u->host); $host =~ s/\.\z//;
    return unless $host =~ /\A(?:(?:www|m|vm|vt)\.)?tiktok\.com\z/;
    my $path = $u->path || '/';
    $path =~ s{\A/%40}{/@}i;
    my $r = {kind=>'link'};
    if ($host =~ /\A(?:vm|vt)\./ || $path =~ m{\A/t/}) {
        return unless $path =~ m{\A/(?:t/)?[A-Za-z0-9_-]{1,100}/?\z};
        $r->{kind} = 'short'; $u->query(undef);
    } else {
        $host = 'www.tiktok.com';
        if ($path =~ m{\A/(@[A-Za-z0-9._]{1,64})/(video|photo)/([0-9]{1,25})/?\z}) {
            @{$r}{qw(owner kind id)} = ($1, $2, $3);
            $path = "/$1/$2/$3"; $u->query(undef);
        } elsif ($path =~ m{\A/(@[A-Za-z0-9._]{1,64})(/live)?/?\z}) {
            $r->{owner} = $1; $r->{kind} = $2 ? 'live' : 'profile';
            $path = $2 ? "/$1/live" : "/$1"; $u->query(undef);
        } elsif ($path =~ m{\A/(?:embed/v2|player/v1|share/video|v)/([0-9]{1,25})(?:\.html)?/?\z}) {
            $r->{id}=$1; $r->{kind}='video'; $u->query(undef);
        }
    }
    $u->scheme('https'); $u->host($host); $u->port(undef);
    $u->path($path); $u->fragment(undef);
    $r->{url} = "$u"; $r->{key} = "$u";
    return $r;
}

sub plain {
    my ($v) = @_;
    return unless defined($v) && !ref($v);
    $v = decode_entities(substr(decode_irc_text($v), 0, 4096));
    $v =~ s{</?[a-z][^>]*>}{}ig;
    $v =~ s/\x03[0-9]{0,2}(?:,[0-9]{1,2})?//g;
    $v =~ s/\x04[0-9a-f]{6}(?:,[0-9a-f]{6})?//ig;
    $v =~ s/[\x00-\x1f\x7f-\x9f\x{200e}\x{200f}\x{202a}-\x{202e}\x{2066}-\x{2069}\x{feff}]/ /g;
    $v =~ s/\s+/ /g; $v =~ s/^\s+|\s+$//g;
    return length($v) ? _clip($v,1024) : undef;
}
sub caption {
    my $v = plain($_[0]);
    return unless defined $v;
    return if $v =~ /\A(?:TikTok(?:\s*[-|–]\s*Make Your Day)?|Make Your Day|Watch trending videos for you|Log in \| TikTok)\z/i;
    return if $v =~ /\A(?:Watch and discover millions of|TikTok is the destination for|Log in to TikTok|Verify to continue)/i;
    return $v;
}
sub _json {
    my ($s) = @_;
    return unless defined($s) && !ref($s) && length($s) <= 1024*1024;
    return eval { JSON::PP->new->utf8(utf8::is_utf8($s) ? 0 : 1)->decode($s) };
}
sub parse_oembed {
    my ($body, $info) = @_;
    my $d = _json($body);
    return {} unless ref($d) eq 'HASH' && !exists($d->{error});
    return {} if defined($d->{embed_product_id}) && defined($info->{id})
        && (ref($d->{embed_product_id}) || "$d->{embed_product_id}" ne $info->{id});
    my $author = url_info($d->{author_url});
    return {caption=>scalar caption($d->{title}), author=>scalar plain($d->{author_name}),
        owner=>$author ? $author->{owner} : undef};
}
sub _attrs {
    my ($s) = @_; my %a;
    while ($s =~ /([A-Za-z_:.-]+)\s*=\s*(["'])(.*?)\2/sg) { $a{lc($1)}=$3 }
    return \%a;
}
sub parse_html {
    my ($html, $info) = @_;
    return {} unless defined($html) && !ref($html) && length($html) <= 1024*1024;
    $html = decode_irc_text($html);
    my ($item, $profile);
    while ($html =~ m{<script\b([^>]*)>(.*?)</script\s*>}sig) {
        my ($attr,$body)=(_attrs($1),$2);
        next unless ($attr->{id}//'') =~ /\A(?:__UNIVERSAL_DATA_FOR_REHYDRATION__|SIGI_STATE)\z/;
        my $d = _json($body); next unless ref($d) eq 'HASH';
        if (($info->{kind}//'') eq 'profile') {
            my $user = eval { $d->{__DEFAULT_SCOPE__}{'webapp.user-detail'}{userInfo} };
            my $name = eval { $user->{user}{uniqueId} };
            $profile=$user if defined($name) && !ref($name) && lc('@'.$name) eq lc($info->{owner});
        }
        if (defined $info->{id}) {
            my $candidate = eval { $d->{__DEFAULT_SCOPE__}{'webapp.video-detail'}{itemInfo}{itemStruct} };
            $candidate = eval { $d->{ItemModule}{$info->{id}} } unless ref($candidate) eq 'HASH';
            $item=$candidate if ref($candidate) eq 'HASH' && defined($candidate->{id})
                && !ref($candidate->{id}) && "$candidate->{id}" eq $info->{id};
        }
    }
    my %r;
    if ($profile) {
        $r{author}=plain($profile->{user}{nickname});
        $r{caption}=caption($profile->{user}{signature});
        my $n=eval {$profile->{stats}{followerCount}};
        $r{followers}=$n if defined($n) && !ref($n) && "$n" =~ /\A[0-9]{1,12}\z/;
    }
    if ($item) {
        $r{caption}=caption($item->{desc});
        if (ref($item->{author}) eq 'HASH') {
            $r{author}=plain($item->{author}{nickname});
            my $name=$item->{author}{uniqueId};
            $r{owner}='@'.$name if defined($name) && !ref($name) && $name =~ /\A[A-Za-z0-9._]{1,64}\z/;
        }
        $r{kind}='photo' if ref($item->{imagePost}) eq 'HASH';
        for my $entry ([seconds=>'video','duration'],[views=>'stats','playCount'],[likes=>'stats','diggCount']) {
            my ($to,$parent,$field)=@$entry;
            my $v=ref($item->{$parent}) eq 'HASH' ? $item->{$parent}{$field} : undef;
            $r{$to}=0+$v if defined($v) && !ref($v) && "$v" =~ /\A[0-9]{1,12}\z/;
        }
    }
    my %meta;
    while ($html =~ /<meta\b([^>]*)>/sig) {
        my $a=_attrs($1); my $k=lc($a->{property}//$a->{name}//'');
        next unless $k =~ /\A(?:og:title|og:description|twitter:description|description)\z/;
        $meta{$k} //= caption($a->{content});
    }
    $r{caption} //= $meta{'og:description'} // $meta{'twitter:description'} // $meta{description} // $meta{'og:title'};
    delete $r{$_} for grep {!defined $r{$_}} keys %r;
    return \%r;
}

# Redirects are followed explicitly, only on the public TikTok host allowlist.
# One worker deadline bounds the entire chain, independently of HTTP timeouts.
sub _http { HTTP::Tiny->new(timeout=>5, max_size=>1024*1024, max_redirect=>0,
    verify_SSL=>1, agent=>'Mozilla/5.0 (compatible; Mediabot TikTok preview)',
    default_headers=>{'accept-language'=>'en-US,en;q=0.8'}) }
sub fetch {
    my ($url) = @_;
    my $info=url_info($url) or return {};
    my $http=_http(); my $page; my %seen;
    # Resolve short/mobile links and normal page redirects with the same
    # allowlist. Never pass an unchecked Location back to the HTTP client.
    for (1..4) {
        last if $seen{$info->{url}}++;
        my $r=eval { $http->get($info->{url}) };
        last unless ref($r) eq 'HASH';
        if (($r->{status}//0) =~ /\A30[12378]\z/) {
            my $loc=ref($r->{headers}) eq 'HASH' ? $r->{headers}{location} : undef;
            last unless defined($loc) && !ref($loc);
            my $next=url_info(eval { URI->new_abs($loc, $info->{url})->as_string });
            last unless $next;
            $info=$next;
        } else { $page=$r; last }
    }
    my %out=(%$info);
    if (ref($page) eq 'HASH' && $page->{success}) {
        my $m=parse_html($page->{content},$info);
        $out{$_}=$m->{$_} for grep {defined $m->{$_}} keys %$m;
    }
    # oEmbed is a second source, not the only source: recent responses may
    # contain only an iframe. No script execution or third-party mirror.
    if (!$out{caption} && $info->{kind} =~ /\A(?:video|photo|profile)\z/) {
        my $r=eval { $http->get('https://www.tiktok.com/oembed?url='.uri_escape_utf8($info->{url})) };
        if (ref($r) eq 'HASH' && $r->{success}) {
            my $o=parse_oembed($r->{content},$info);
            $out{$_}=$o->{$_} for grep {defined $o->{$_}} keys %$o;
        }
    }
    return \%out;
}
sub _clip {
    my ($s,$n)=@_;
    return _irc_wire_bytes($s) <= $n ? $s : _irc_prefix_for_budget($s,$n-3).'…';
}
sub _count {
    my ($n)=@_; return unless defined($n) && !ref($n) && "$n" =~ /\A[0-9]{1,12}\z/;
    return sprintf('%.1fM',$n/1e6) if $n>=1e6;
    return sprintf('%.1fk',$n/1e3) if $n>=1e3;
    return $n;
}
sub render {
    my ($nick,$info,$raw)=@_;
    $raw={} unless ref($raw) eq 'HASH';
    my $kind=plain($raw->{kind}) // $info->{kind} // 'link';
    my %label=(video=>'🎬', photo=>'📷', profile=>'👤', live=>'🔴 Live', link=>'🔗', short=>'🔗');
    my $owner=plain($raw->{owner}) // $info->{owner};
    my $author=plain($raw->{author});
    my $who=defined($owner) ? $owner : $author;
    my $line='('._clip(plain($nick)//'',60).") \x0300,01[TikTok]\x0f ".($label{$kind}//'🔗');
    $line.=' '."\x02"._clip($who,64)."\x02" if defined $who;
    if (defined($owner) && defined($author) && lc($author) ne lc(substr($owner,1))) {
        $line.=' ('._clip($author,48).')';
    }
    my @meta;
    my $sec=$raw->{seconds};
    push @meta,sprintf('%d:%02d',int($sec/60),$sec%60) if defined($sec) && !ref($sec) && "$sec" =~ /\A[0-9]{1,6}\z/ && $sec>0;
    for my $field (qw(views likes followers)) {
        my $v=_count($raw->{$field});
        push @meta,($field eq 'views' ? '👁 ' : $field eq 'likes' ? '♥ ' : '👥 ').$v if defined $v;
    }
    my $tail=@meta ? ' · '.join(' · ',@meta) : '';
    my $text=caption($raw->{caption}) // 'aperçu indisponible';
    my $budget=400-_irc_wire_bytes($line.' — '.$tail."\x0f");
    return $line.' — '._clip($text,$budget).$tail."\x0f";
}
sub enabled {
    require Mediabot::External;
    return Mediabot::External::_chanset_ok($_[0],$_[1],'UrlTitle');
}

sub handle {
    my ($bot, $message, $nick, $channel, $url) = @_;
    my $info = url_info($url);
    return 0 unless $info && enabled($bot, $channel);
    my $binding = capture_delivery_context($bot, $channel);
    my $current = sub { delivery_context_current($bot, $binding)
        && enabled($bot, $channel) };
    my $loop = eval { $bot->getLoop };
    $loop ||= $bot->{loop};
    return 0 unless $loop && eval { $loop->can('add') && $loop->can('remove') && $loop->can('watch_process') };
    my $state = $bot->{_tiktok_preview} //= {cache=>{}, pending=>{}, recent=>{}, starts=>[]};
    my $now = time;
    delete $state->{cache}{$_} for grep {$state->{cache}{$_}{until} <= $now} keys %{$state->{cache}};
    delete $state->{recent}{$_} for grep {$state->{recent}{$_} <= $now-300} keys %{$state->{recent}};
    my $request = lc($channel)."\0".$info->{key};
    return 1 if exists $state->{recent}{$request};
    return 0 if keys(%{$state->{recent}}) >= 512;
    my $send = sub {
        my ($value) = @_;
        return unless $current->();
        require Mediabot::Helpers;
        Mediabot::Helpers::botPrivmsg($bot, $channel, render($nick, $info, $value), {no_defer=>1});
    };
    if (my $cache = $state->{cache}{$info->{key}}) {
        $state->{recent}{$request} = $now;
        $send->($cache->{value});
        return 1;
    }
    if (my $pending = $state->{pending}{$info->{key}}) {
        return 0 if @{$pending->{send}} >= 16;
        push @{$pending->{send}}, $send;
        $state->{recent}{$request} = $now;
        return 1;
    }
    @{$state->{starts}} = grep {$_ > $now-60} @{$state->{starts}};
    return 0 if keys(%{$state->{pending}}) >= 4 || @{$state->{starts}} >= 12;
    push @{$state->{starts}}, $now;
    $state->{recent}{$request} = $now;
    my $attempt = {send=>[$send]};
    $state->{pending}{$info->{key}} = $attempt;
    my $done = 0;
    my $complete = sub {
        my ($result) = @_;
        return if $done++;
        return unless $state->{pending}{$info->{key}}
            && refaddr($state->{pending}{$info->{key}}) == refaddr($attempt);
        delete $state->{pending}{$info->{key}};
        my $value = (ref($result) eq 'HASH' && $result->{ok} && ref($result->{value}) eq 'HASH' ? $result->{value} : {});
        $state->{cache}{$info->{key}} = {until=>time+(caption($value->{caption}) ? 300 : 30), value=>$value};
        while (keys(%{$state->{cache}}) > 128) {
            my ($old) = sort {$state->{cache}{$a}{until} <=> $state->{cache}{$b}{until}} keys %{$state->{cache}};
            delete $state->{cache}{$old};
        }
        for my $recipient (@{$attempt->{send}}) { eval { $recipient->($value) } }
        $attempt->{send} = [];
    };
    my $worker = eval { Mediabot::AsyncWorker->start(loop=>$loop, label=>'TikTok preview', timeout=>16, max_output=>16384,
        child=>sub {
            eval {$bot->{dbh}{InactiveDestroy}=1 if $bot->{dbh}};
            eval {$bot->{db}{dbh}{InactiveDestroy}=1 if $bot->{db} && $bot->{db}{dbh}};
            return fetch($info->{url});
        }, on_done=>$complete) };
    $complete->({ok=>0}) unless $worker || $done;
    return 1;
}

1;
