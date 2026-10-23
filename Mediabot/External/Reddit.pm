package Mediabot::External::Reddit;

use strict;
use warnings;
use utf8;
use URI ();
use URI::Escape qw(uri_escape_utf8);
use HTML::Entities qw(decode_entities);
use Scalar::Util qw(refaddr);
use POSIX qw(strftime);
use Time::HiRes ();
use Mediabot::JSON qw(decode_json_payload);
use Mediabot::AsyncWorker ();
use Mediabot::IRC::Text qw(decode_irc_text);
use Mediabot::IRC::TextBudget qw(_irc_wire_bytes _irc_prefix_for_budget);
use Mediabot::IRC::DeliveryContext qw(capture_delivery_context delivery_context_current);

sub badge { return "\x0301,07[reddit]\x0f" }

# Public hosts only. Parse the authority rather than matching a nested URL.
sub is_reddit_url {
    my ($url) = @_;
    return 0 unless defined($url) && !ref($url) && length($url) <= 2048;
    my $u = eval { URI->new($url) };
    return 0 unless $u && ($u->scheme // '') =~ /\Ahttps?\z/i;
    my $host = eval { lc($u->host // '') } // '';
    $host =~ s/\.\z//;
    return $host =~ /\A(?:(?:[a-z0-9-]+\.)*reddit\.com|(?:i\.|v\.|preview\.|external-preview\.)?redd\.it|(?:www\.)?redditmedia\.com|reddit\.app\.link)\z/ ? 1 : 0;
}

sub _network_url {
    my ($url) = @_;
    return unless defined($url) && !ref($url) && length($url) <= 8192
        && $url !~ /[\x00-\x20\x7f\\]/ && $url !~ /%(?:0[0-9a-f]|1[0-9a-f]|7f)/i;
    my $u = eval { URI->new($url) };
    return unless $u && ($u->scheme // '') =~ /\Ahttps?\z/i
        && !defined($u->userinfo);
    my $port=$u->port;
    return unless defined($port) && !ref($port) && $port =~ /\A[0-9]{1,5}\z/
        && $port == (($u->scheme =~ /\Ahttps\z/i) ? 443 : 80);
    # is_reddit_url has the shorter pasted-link limit; check a clean authority
    # separately because an encoded oEmbed query can legitimately be longer.
    my $host = lc($u->host // '');
    $host =~ s/\.\z//;
    return unless is_reddit_url('https://' . $host . '/');
    $u->scheme('https'); $u->host($host); $u->port(undef); $u->fragment(undef);
    return $u->as_string;
}

sub url_info {
    my ($url) = @_;
    return unless is_reddit_url($url);
    my $safe = _network_url($url); return unless $safe;
    my $u = URI->new($safe);
    my ($host,$path) = (lc($u->host),$u->path // '/');
    return if $path =~ m{(?:\A|/)(?:\.|%2e){1,2}(?:/|\z)}i || $path =~ /%(?![0-9a-f]{2})/i;
    $path =~ s{/+}{/}g;
    $path =~ s{/+\z}{}; $path = '/' unless length $path;
    my $info = {kind=>'link',url=>$safe,key=>'link:'.$safe};
    if ($host =~ /\A(?:i|preview|external-preview)\.redd\.it\z/) {
        return {kind=>'image',url=>$safe,key=>$host.':'.$path};
    }
    if ($host eq 'v.redd.it') {
        return {kind=>'video',url=>$safe,key=>$host.':'.$path};
    }
    if ($host eq 'reddit.app.link') {
        return {kind=>'share',url=>$safe,key=>'share:'.$path};
    }
    # Resolve short IDs directly, without following a redirect to a foreign host.
    if ($host eq 'redd.it' && $path =~ m{\A/([a-z0-9]{1,16})\z}i) {
        my $id=lc($1);
        $host='www.reddit.com';$path='/comments/'.$id;
    }
    return $info if $host eq 'redd.it';
    # Reddit's public media wrapper deliberately selects one owned CDN URL.
    if ($path eq '/media') {
        my @query=$u->query_form;my @targets;
        while (@query) {my ($k,$v)=splice(@query,0,2);push @targets,$v if $k eq 'url'}
        return unless @targets==1;
        my $target=_network_url($targets[0]);return unless $target;
        my $m=URI->new($target);
        return unless $m->host =~ /\A(?:i|v|preview|external-preview)\.redd\.it\z/i;
        return url_info($target);
    }
    # Standard, old/mobile/language and legacy iframe frontends share identity.
    my ($sub,$owner,$post,$comment);
    if ($path =~ m{\A/r/([a-z0-9_]{1,32})/comments/([a-z0-9]{1,16})(?:/[^/]+)?(?:/([a-z0-9]{1,16}))?\z}i) {
        ($sub,$post,$comment)=($1,lc($2),defined($3)?lc($3):undef);
    }
    elsif ($path =~ m{\A/user/([a-z0-9_-]{1,32})/comments/([a-z0-9]{1,16})(?:/[^/]+)?(?:/([a-z0-9]{1,16}))?\z}i) {
        ($owner,$post,$comment)=($1,lc($2),defined($3)?lc($3):undef);
    }
    elsif ($path =~ m{\A/comments/([a-z0-9]{1,16})(?:/[^/]+)?(?:/([a-z0-9]{1,16}))?\z}i) {
        ($post,$comment)=(lc($1),defined($2)?lc($2):undef);
    }
    elsif ($path =~ m{\A/(?:gallery/|t3_)([a-z0-9]{1,16})\z}i) { $post=lc($1) }
    if ($post) {
        my @query = $u->query_form;
        my @comments;
        while (@query) {my ($k,$v)=splice(@query,0,2);push @comments,$v if lc($k) eq 'comment'}
        return if @comments>1;
        if (@comments) {
            return unless defined($comments[0]) && $comments[0] =~ /\A[a-z0-9]{1,16}\z/i;
            return if defined($comment) && lc($comments[0]) ne $comment;
            $comment=lc($comments[0]);
        }
        my $fragment=URI->new($url)->fragment // '';
        if ($fragment =~ /\At1_([a-z0-9]{1,16})\z/i) {
            return if defined($comment) && $comment ne lc($1);
            $comment=lc($1);
        }
        my $base=defined($sub) ? "/r/$sub/comments/$post" : defined($owner) ? "/user/$owner/comments/$post" : "/comments/$post";
        my $target='https://www.reddit.com'.$base.(defined($comment)?"/comment/$comment/":'/');
        return {kind=>defined($comment)?'comment':'post',post=>$post,
            (defined($comment)?(comment=>$comment):()),(defined($sub)?(subreddit=>$sub):()),
            url=>$target,key=>defined($comment)?"comment:$post:$comment":"post:$post"};
    }
    return if $path =~ m{\A/(?:r/[^/]+/|user/[^/]+/)?comments(?:/|\z)}i;
    if ($path =~ m{\A/(?:r/[a-z0-9_]{1,32}/)?s/[a-z0-9_-]{1,128}\z}i) {
        return {kind=>'share',url=>'https://www.reddit.com'.$path,key=>'share:'.$path};
    }
    my $kind='link';
    if ($path =~ m{\A/r/([a-z0-9_+]{1,80})(?:/|\z)}i) {$kind='community';$info->{subreddit}=$1}
    elsif ($path =~ m{\A/(?:user|u)/([a-z0-9_-]{1,32})(?:/|\z)}i) {$kind='profile';$info->{author}=$1}
    # No cookies/session data are sent. Do not fetch account or login pages.
    my $private=$path =~ m{\A/(?:login|register|account|settings|prefs|message|chat|api|api-docs)(?:/|\z)}i ? 1 : 0;
    $u->host('www.reddit.com');$u->path($path);
    my @query=$u->query_form;my @keep;
    while (@query) {my ($k,$v)=splice(@query,0,2);push @keep,$k,$v if $k =~ /\A(?:q|sort|t|f|restrict_sr)\z/}
    $u->query_form(@keep);$u->query(undef) unless @keep;
    $info->{kind}=$kind;$info->{url}=$u->as_string;$info->{key}=$kind.':'.$info->{url};$info->{private}=$private;
    return $info;
}

# Fresh membership, deliberately off when the new catalogue row is missing.
sub enabled {
    my ($bot,$channel)=@_;
    return 0 unless defined($channel) && !ref($channel) && $channel =~ /\A#[^\x00-\x20\x7f,:]{1,254}\z/;
    my $on=eval {
        my $db=$bot->{db} ? $bot->{db}->ensure_connected : $bot->{dbh};
        return 0 unless $db;
        my $sth=$db->prepare(q{SELECT CS.id_channel_set FROM CHANNEL_SET CS
            JOIN CHANNEL C ON C.id_channel=CS.id_channel
            JOIN CHANSET_LIST CL ON CL.id_chanset_list=CS.id_chanset_list
            WHERE C.name=? AND CL.chanset=?}) or return 0;
        my $ok=$sth->execute($channel,'Reddit');
        my $row=$ok ? $sth->fetchrow_arrayref : undef;
        my $error=$sth->err;$sth->finish;
        return $ok && !$error && $row ? 1 : 0;
    };
    return $on ? 1 : 0;
}
sub register_chanset {
    my ($bot)=@_;my $db=$bot->{dbh} or return;
    return eval {
        my $sth=$db->prepare(q{INSERT INTO CHANSET_LIST(chanset) SELECT ? WHERE NOT EXISTS(SELECT 1 FROM CHANSET_LIST WHERE chanset=?)}) or return;
        my $ok=$sth->execute('Reddit','Reddit');$sth->finish;return $ok ? 1 : undef;
    };
}
sub epoch { return $_[0]{_reddit_epoch}{lc($_[1])}//0 }
sub note_policy_change { return ++$_[0]{_reddit_epoch}{lc($_[1])} }

sub _plain {
    my ($value,$max)=@_;
    return unless defined($value) && !ref($value);
    $value=decode_irc_text($value);
    $value=substr($value,0,$max//1024);
    $value=decode_entities($value);
    $value =~ s{</?[a-z][^>]*>}{}ig;
    $value =~ s/\x03[0-9]{0,2}(?:,[0-9]{1,2})?//g;
    $value =~ s/\x04[0-9a-f]{6}(?:,[0-9a-f]{6})?//ig;
    $value =~ s/[\x00-\x1f\x7f-\x9f\x{200e}\x{200f}\x{202a}-\x{202e}\x{2066}-\x{2069}\x{feff}]/ /g;
    $value =~ s/\s+/ /g;$value =~ s/^\s+|\s+$//g;
    return length($value) ? $value : undef;
}
sub _title {
    my ($value)=@_;my $s=_plain($value,1024);return unless defined $s;
    return if $s =~ /\A(?:reddit(?:\s*[:|–-]\s*(?:dive into anything|the front page of the internet))?|just a moment\.*|access denied|403 forbidden|404 not found|page not found|blocked|error)\z/i;
    return if $s =~ /(?:log in|sign in|se connecter).*(?:reddit)|blocked by network security|verify (?:you are|that you.re) human|private community|communauté privée/i;
    $s =~ s/\s+(?:[|–-]|:)\s+Reddit\s*\z//i;
    return $s;
}
sub _tree {
    my ($html)=@_;return unless defined($html) && !ref($html) && length($html)<=512*1024;
    require HTML::TreeBuilder;
    my $tree=HTML::TreeBuilder->new;
    $tree->store_comments(0);$tree->ignore_unknown(0);
    $tree->parse_content(decode_irc_text($html));
    return $tree;
}
sub _user {
    my ($s)=@_;return unless defined($s) && !ref($s);
    $s =~ s{\A/?u(?:ser)?/}{}i;
    return $s =~ /\A[a-z0-9_-]{1,32}\z/i ? $s : undef;
}
sub _subreddit {
    my ($s)=@_;return unless defined($s) && !ref($s);
    $s =~ s{\A/?r/}{}i;
    return $s =~ /\A[a-z0-9_+]{1,80}\z/i ? $s : undef;
}
sub _number {
    my ($s)=@_;return unless defined($s) && !ref($s) && $s =~ /\A-?[0-9]{1,10}\z/;
    return 0+$s;
}
sub _timestamp {
    my ($s)=@_;return unless defined($s) && !ref($s) && $s =~ /\A(?:[0-9]{10}|[0-9]{13})\z/;
    my $seconds=length($s)==13 ? int($s/1000) : 0+$s;
    return $seconds>=1104537600 && $seconds<=time+86400 ? $seconds : undef;
}
sub _content_type {
    my ($s)=@_;return unless defined($s) && !ref($s);
    return $s =~ /\A(?:text|image|video|link|gallery|poll|crosspost)\z/ ? $s : undef;
}
sub _embed_entity {
    my ($data,$info)=@_;return unless ref($data) eq 'HASH';
    if ($info->{kind} eq 'comment') {
        my $c=$data->{comment};return unless ref($c) eq 'HASH';
        return unless defined($c->{id}) && !ref($c->{id}) && $c->{id} eq 't1_'.$info->{comment}
            && defined($c->{post_id}) && !ref($c->{post_id}) && $c->{post_id} eq 't3_'.$info->{post};
        return $c;
    }
    my $p=$data->{post};return unless ref($p) eq 'HASH';
    return unless defined($p->{id}) && !ref($p->{id}) && $p->{id} eq 't3_'.$info->{post};
    my $link=url_info($p->{url});
    return $link && $link->{key} eq $info->{key} ? $p : undef;
}

# Public iframe rendered by Reddit's own widgets.js. Read its static, exact-ID
# wrapper and explicitly bound counters; never execute scripts or read a feed's
# first count. Optional detail failure must leave the valid oEmbed intact.
sub parse_embed {
    my ($html,$info)=@_;
    return unless ref($info) eq 'HASH' && ($info->{kind}//'') =~ /\A(?:post|comment)\z/;
    my $tree=_tree($html);return unless $tree;
    my $thing=$info->{kind} eq 'comment' ? 't1_'.$info->{comment} : 't3_'.$info->{post};
    my @wrappers=$tree->look_down(id=>$thing.'-embed-wrapper');
    my ($wrapper,$entity);
    if (@wrappers==1) {
        for my $tag ($tree->look_down(_tag=>'shreddit-screenview-data')) {
            my $raw=$tag->attr('data');next unless defined($raw) && !ref($raw) && length($raw)<=16384;
            my $data=eval {decode_json_payload($raw)};
            $entity=_embed_entity($data,$info);last if $entity;
        }
        $wrapper=$wrappers[0] if $entity;
    }
    unless ($wrapper) {$tree->delete;return}
    my @links=$wrapper->look_down(_tag=>'embed-event-handler');
    my $bound=grep {
        my $u=url_info($_->attr('link'));
        ($_->attr('id')//'') eq $thing && $u && $u->{key} eq $info->{key}
    } @links;
    unless ($bound) {$tree->delete;return}
    my $out={};
    $out->{created}=_timestamp($entity->{created_timestamp});
    $out->{content_type}=_content_type($entity->{type}) if $info->{kind} eq 'post';
    $out->{score}=_number($entity->{score});
    for my $flag (qw(nsfw spoiler)) {
        my $v=$entity->{$flag};
        $out->{$flag}=1 if defined($v) && (JSON::MaybeXS::is_bool($v) ? $v : !ref($v) && "$v" eq '1');
    }
    for my $tracker ($wrapper->look_down(_tag=>'faceplate-tracker')) {
        my $raw=$tracker->attr('data-faceplate-tracking-context');
        next unless defined($raw) && !ref($raw) && length($raw)<=16384;
        my $context=eval {decode_json_payload($raw)};
        next unless _embed_entity($context,$info) && ref($context->{action_info}) eq 'HASH';
        my $type=$context->{action_info}{type};next unless defined($type) && !ref($type);
        my $field=$type eq 'upvote' ? 'score'
            : $type eq 'comments' && $info->{kind} eq 'post' ? 'comments'
            : $type eq 'replies' && $info->{kind} eq 'comment' ? 'replies' : undef;
        next unless $field;
        my @values=grep {
            my ($owner)=grep {$_->tag eq 'faceplate-tracker'} $_->lineage;
            $owner && refaddr($owner)==refaddr($tracker);
        } $tracker->look_down(_tag=>'faceplate-number');next unless @values==1;
        my $number=_number($values[0]->attr('number'));
        $out->{$field}=$number if defined($number) && ($field eq 'score' || $number>=0);
    }
    if ($info->{kind} eq 'comment') {
        my @bodies=$wrapper->look_down(id=>$thing.'-post-rtjson-content');
        if (@bodies==1) {
            # Paragraphs preserve prose. Do not flatten ASCII art/code-only
            # comments or promote a quoted block into the author's response.
            my @paragraphs=grep {
                my $quoted=0;
                for my $parent ($_->lineage) {$quoted=1 if $parent->tag =~ /\A(?:blockquote|pre|code|script|style)\z/}
                !$quoted;
            } $bodies[0]->look_down(_tag=>'p');
            my $body=_plain(join(' ',map {$_->as_text} @paragraphs),1024);
            if (defined($body)) {
                if ($body =~ /\A\[(?:deleted|removed)\]\z/i) {$out->{removed}=1}
                else {$out->{comment_text}=$body}
            }
        }
    }
    $tree->delete;
    delete $out->{$_} for grep {!defined($out->{$_})} keys %$out;
    return $out;
}
sub parse_oembed {
    my ($payload,$info)=@_;
    my $data=eval {decode_json_payload($payload)};
    return unless ref($data) eq 'HASH' && ref($info) eq 'HASH';
    return unless defined($data->{provider_name}) && !ref($data->{provider_name}) && lc($data->{provider_name}) eq 'reddit';
    my $tree=_tree($data->{html});return unless $tree;
    my ($matched,$sub,$author,$comment_text,$parent_title,$has_parent,$context_only,$permalink);
    for my $a ($tree->look_down(_tag=>'a')) {
        my $href=$a->attr('href');
        my $absolute=defined($href) && !ref($href) ? eval {URI->new_abs($href,'https://www.reddit.com/')->as_string} : undef;
        my $target=url_info($absolute);
        next unless $target;
        if ($target->{key} eq $info->{key}) {$matched=$a;$sub=$target->{subreddit};$permalink=$target->{url}}
        if ($info->{kind} eq 'comment' && $target->{kind} eq 'post' && $target->{post} eq $info->{post}) {
            $has_parent=1;$parent_title=_title($a->as_text);
        }
    }
    my $title;
    if ($matched) {
        if ($info->{kind} eq 'comment') {
            # Official comment embeds put the quoted body in their first p.
            my $p=$tree->look_down(_tag=>'p');$comment_text=_plain($p->as_text,1024) if $p;
            $title=$comment_text;
            if (!defined($title) && $has_parent) {
                $title=$parent_title // _title($data->{title});$context_only=1;
            }
        }
        else {$title=_title($data->{title}) // _title($matched->as_text)}
    }
    # A quoted comment can itself link to other users/communities. Attribution
    # comes from the provider field and the identity-matched permalink only.
    $author = _user($data->{author_name});
    $tree->delete;
    return unless $matched && defined($title);
    return {state=>'missing'} if $title =~ /\A\[(?:deleted|removed)\]\z/i;
    return {state=>'ok',kind=>$info->{kind},title=>$title,permalink=>$permalink,
        ($context_only ? (context_only=>1) : ()),
        (defined($sub)?(subreddit=>$sub):()),(defined($author)?(author=>$author):())};
}
sub parse_html {
    my ($html,$info)=@_;
    my $tree=_tree($html);return unless $tree;
    my %meta;
    for my $m ($tree->look_down(_tag=>'meta')) {
        my $name=lc($m->attr('property')//$m->attr('name')//'');
        next unless $name =~ /\A(?:og:title|og:description|og:url|description|author|twitter:title|twitter:description)\z/;
        $meta{$name}//=$m->attr('content');
    }
    my $title=$meta{'og:title'}//$meta{'twitter:title'};
    my $page_title=$tree->look_down(_tag=>'title');$title//=$page_title->as_text if $page_title;
    my $canonical=$meta{'og:url'};
    if (!defined($canonical)) {my ($a)=grep {lc($_->attr('rel')//'') eq 'canonical'} $tree->look_down(_tag=>'link');$canonical=$a->attr('href') if $a}
    my $absolute=defined($canonical) && !ref($canonical) ? eval {URI->new_abs($canonical,$info->{url})->as_string} : undef;
    my $resolved=url_info($absolute);
    my $out={state=>'ok',kind=>$info->{kind}};
    if ($info->{post}) {
        my @posts=$tree->look_down(_tag=>'shreddit-post');
        my ($post)=grep {($_->attr('id')//$_->attr('post-id')//'') eq 't3_'.$info->{post}} @posts;
        if ($post) {
            $title=$post->attr('post-title')//$title;
            $out->{author}=_user($post->attr('author'));
            $out->{subreddit}=_subreddit($post->attr('subreddit-prefixed-name')//$post->attr('subreddit-name'));
            $out->{score}=_number($post->attr('score'));
            $out->{comments}=_number($post->attr('comment-count'));
            $out->{nsfw}=1 if defined($post->attr('nsfw')) || ($post->attr('is-nsfw')//'') eq 'true';
            $out->{spoiler}=1 if defined($post->attr('spoiler')) || ($post->attr('is-spoiler')//'') eq 'true';
        }
        $title=undef unless $post || ($resolved && ($resolved->{post}//'') eq $info->{post});
        # A comment URL must never silently display the parent post's title.
        if ($info->{kind} eq 'comment') {
            my ($comment)=grep {($_->attr('thingid')//$_->attr('id')//'') eq 't1_'.$info->{comment}}
                $tree->look_down(_tag=>'shreddit-comment');
            $title=undef;
            if ($comment) {
                my ($body)=grep {($_->attr('slot')//'') eq 'comment'} $comment->look_down(_tag=>'div');
                $title=_plain($body->as_text,1024) if $body;
                $out->{author}=_user($comment->attr('author'));
                $out->{score}=_number($comment->attr('score'));
                delete $out->{comments};
            }
        }
    }
    elsif ($info->{kind} eq 'profile' || $info->{kind} eq 'community') {
        # Do not mistake a feed's first post for the community/profile itself.
        $out->{author}=$info->{author} if $info->{kind} eq 'profile';
        $out->{subreddit}=$info->{subreddit} if $info->{kind} eq 'community';
    }
    $out->{title}=_title($title);
    $out->{resolved_url}=$resolved->{url} if $resolved && $resolved->{kind} =~ /\A(?:post|comment)\z/;
    $tree->delete;
    return unless defined($out->{title}) || ($info->{kind} eq 'share' && $out->{resolved_url});
    delete $out->{$_} for grep {!defined($out->{$_})} keys %$out;
    return $out;
}

sub _http {
    require HTTP::Tiny;
    return HTTP::Tiny->new(timeout=>6,verify_SSL=>1,max_redirect=>0,max_size=>512*1024,
        agent=>'Mediabot-RedditPreview/1.0 (+https://github.com/teuk/mediabot_v3)');
}
sub _request {
    my ($http,$method,$url,$max_redirects)=@_;$max_redirects//=2;
    for my $hop (0..$max_redirects) {
        my $safe=_network_url($url);return {success=>0,status=>0} unless $safe;
        my $r=eval {$http->request($method,$safe,{headers=>{Accept=>'application/json, text/html;q=0.9'}})};
        return {success=>0,status=>0} unless ref($r) eq 'HASH';
        if (($r->{status}//0) =~ /\A(?:301|302|303|307|308)\z/) {
            return {success=>0,status=>0} if $hop==$max_redirects || ref($r->{headers}) ne 'HASH';
            my $location=$r->{headers}{location};return {success=>0,status=>0} unless defined($location) && !ref($location);
            $url=eval {URI->new_abs($location,$safe)->as_string};
            next;
        }
        return {%$r,final_url=>$safe};
    }
    return {success=>0,status=>0};
}
sub _unavailable {
    my ($response)=@_;my $state='unavailable';
    $state='restricted' if ($response->{status}//0) =~ /\A(?:401|403)\z/;
    $state='missing' if ($response->{status}//0) =~ /\A(?:404|410)\z/;
    $state='busy' if ($response->{status}//0) eq '429';
    my $out={state=>$state};
    if ($state eq 'busy') {
        my $raw=ref($response->{headers}) eq 'HASH' ? $response->{headers}{'retry-after'} : undef;
        my $seconds;
        if (defined($raw) && !ref($raw) && $raw =~ /\A[0-9]{1,8}\z/) {$seconds=0+$raw}
        elsif (defined($raw) && !ref($raw)) {
            my $when=eval {require HTTP::Date;HTTP::Date::str2time($raw)};
            $seconds=$when-time if defined($when) && !ref($when);
        }
        $seconds=60 unless defined($seconds) && $seconds>0;
        $seconds=86400 if $seconds>86400;$out->{backoff}=$seconds;
    }
    return $out;
}
sub _enrich {
    my ($http,$info,$out,$deadline)=@_;
    return $out unless $out && $out->{state} eq 'ok';
    my $permalink=url_info($out->{permalink}//$info->{url});
    return $out unless $permalink && $permalink->{key} eq $info->{key};
    my $budget=6;my $remaining=$deadline-Time::HiRes::time();
    return $out if $remaining<=0.1;$budget=$remaining if $remaining<$budget;
    # fetch normally runs in a fresh worker or the standalone checker. An
    # external caller's existing alarm owns its deadline: skip optional work.
    my $previous=Time::HiRes::alarm(0);
    if ($previous>0) {Time::HiRes::alarm($previous);return $out}
    my $u=URI->new($permalink->{url});$u->host('embed.reddit.com');
    my ($extra,$details);
    {
        local $SIG{ALRM}=sub {die "Reddit detail deadline\n"};
        Time::HiRes::alarm($budget);
        eval {
            # One optional iframe request, with no redirect retries and an
            # absolute deadline. Keep usable basic metadata on every failure.
            $extra=_request($http,'GET',$u->as_string,0);
            $details=parse_embed($extra->{content},$info) if $extra->{success};
            1;
        };
        Time::HiRes::alarm(0);
    }
    if ($details) {
        return {state=>'missing'} if $details->{removed};
        $out->{$_}=$details->{$_} for grep {exists($details->{$_})} qw(score comments replies created content_type nsfw spoiler);
        if (defined($details->{comment_text})) {$out->{title}=$details->{comment_text};delete $out->{context_only}}
    }
    elsif ($extra && ($extra->{status}//0)==429) {$out->{backoff}=_unavailable($extra)->{backoff}}
    return $out;
}
sub fetch {
    my ($url)=@_;
    my $detail_deadline=Time::HiRes::time()+26;
    my $info=url_info($url);return {state=>'unavailable'} unless $info && !$info->{private};
    my $http=_http();
    if ($info->{kind} eq 'share' || $info->{kind} eq 'image' || $info->{kind} eq 'video') {
        my $media=$info->{kind} eq 'image' || $info->{kind} eq 'video';
        my $r=_request($http,$media?'HEAD':'GET',$info->{url});
        my $resolved=url_info($r->{final_url});
        if ($r->{success} && $resolved && $resolved->{kind} =~ /\A(?:post|comment)\z/) {
            unless ($media) {
                my $m=parse_html($r->{content},$resolved);
                return _enrich($http,$resolved,$m,$detail_deadline) if $m && defined($m->{title});
            }
            $info=$resolved;
        }
        elsif ($media) {
            return {%{_unavailable($r)}} unless $r->{success};
            my $type=ref($r->{headers}) eq 'HASH' ? $r->{headers}{'content-type'}//'' : '';
            return {state=>'ok',kind=>$info->{kind},title=>$info->{kind} eq 'image'?'Image Reddit':'Vidéo Reddit',media=>1,
                ($type =~ m{\A(?:image|video)/([a-z0-9.+-]{1,30})(?:;|\z)}i ? (format=>uc($1)):())};
        }
        elsif ($r->{success}) {
            my $m=parse_html($r->{content},$info);
            my $target=$m ? url_info($m->{resolved_url}) : undef;
            return $m if $m && !$target && defined($m->{title});
            return {state=>'unavailable'} unless $target;
            $info=$target;
        }
        else {return _unavailable($r)}
    }
    if ($info->{kind} eq 'post' || $info->{kind} eq 'comment') {
        # oEmbed rejects /comments/ID and redd.it/ID directly. Reddit's public
        # r/all post route accepts the ID without guessing its community. The
        # response still has to contain a permalink with this exact identity;
        # attribution comes from that permalink, never from r/all.
        my $lookup=$info->{url};
        if (!$info->{subreddit}) {
            $lookup='https://www.reddit.com/r/all/comments/'.$info->{post}.
                (defined($info->{comment})?'/comment/'.$info->{comment}.'/':'/');
        }
        my $endpoint='https://www.reddit.com/oembed?url='.uri_escape_utf8($lookup).'&format=json&live=true';
        my $r=_request($http,'GET',$endpoint);
        return _unavailable($r) unless $r->{success};
        my $out=parse_oembed($r->{content},$info);
        return _enrich($http,$info,$out,$detail_deadline) // {state=>'unavailable'};
    }
    my $r=_request($http,'GET',$info->{url});
    return _unavailable($r) unless $r->{success};
    return parse_html($r->{content},$info) // {state=>'unavailable'};
}

sub _result {
    my ($r)=@_;return {state=>'unavailable'} unless ref($r) eq 'HASH';
    my $state=$r->{state};return {state=>'unavailable'} unless defined($state) && !ref($state) && $state =~ /\A(?:ok|restricted|missing|busy|unavailable)\z/;
    my $out={state=>$state};
    if ($state eq 'ok') {
        $out->{title}=_title($r->{title});return {state=>'unavailable'} unless defined($out->{title});
        $out->{author}=_user($r->{author});$out->{subreddit}=_subreddit($r->{subreddit});
        $out->{score}=_number($r->{score});$out->{comments}=_number($r->{comments});
        $out->{replies}=_number($r->{replies});$out->{created}=_timestamp($r->{created});
        $out->{content_type}=_content_type($r->{content_type});
        $out->{kind}=$r->{kind} if defined($r->{kind}) && !ref($r->{kind}) && $r->{kind} =~ /\A(?:post|comment|profile|community|image|video|share|link)\z/;
        $out->{$_}=1 for grep {defined($r->{$_}) && !ref($r->{$_}) && "$r->{$_}" eq '1'} qw(nsfw spoiler media context_only);
        $out->{format}=$r->{format} if defined($r->{format}) && !ref($r->{format}) && $r->{format} =~ /\A[A-Z0-9.+-]{1,30}\z/;
    }
    delete $out->{comments} if defined($out->{comments}) && $out->{comments}<0;
    delete $out->{replies} if defined($out->{replies}) && $out->{replies}<0;
    delete $out->{comments} if ($out->{kind}//'') eq 'comment';
    delete $out->{replies} unless ($out->{kind}//'') eq 'comment';
    $out->{backoff}=0+$r->{backoff} if defined($r->{backoff}) && !ref($r->{backoff}) && $r->{backoff} =~ /\A[0-9]{1,5}\z/ && $r->{backoff}<=86400;
    delete $out->{$_} for grep {!defined($out->{$_})} keys %$out;
    return $out;
}
sub render {
    my ($nick,$info,$raw)=@_;return unless ref($info) eq 'HASH';
    my $r=_result($raw);$nick=_irc_prefix_for_budget(_plain($nick,80)//'',80);
    my $prefix="($nick) ".badge().' ';
    my $title=$r->{title};
    my @meta;
    if ($r->{state} eq 'ok') {
        push @meta,'r/'.$r->{subreddit} if $r->{subreddit};
        push @meta,'u/'.$r->{author} if $r->{author};
        $title='Commentaire sur « '.$title.' »' if $r->{context_only} && ($r->{kind}//$info->{kind}) eq 'comment';
        push @meta,'commentaire' if !$r->{context_only} && ($r->{kind}//$info->{kind}) eq 'comment';
        push @meta,'NSFW' if $r->{nsfw};push @meta,'spoiler' if $r->{spoiler};
        push @meta,$r->{score}.' pts' if defined($r->{score});
        push @meta,$r->{comments}.($r->{comments}==1?' commentaire':' commentaires') if defined($r->{comments});
        push @meta,$r->{replies}.($r->{replies}==1?' réponse':' réponses') if defined($r->{replies});
        push @meta,strftime('%d/%m/%Y',gmtime($r->{created})) if $r->{created};
        my %type=(text=>'texte',image=>'image',video=>'vidéo',link=>'lien',gallery=>'galerie',poll=>'sondage',crosspost=>'crosspost');
        push @meta,$type{$r->{content_type}} if $r->{content_type} && ($r->{kind}//$info->{kind}) eq 'post';
        push @meta,$r->{format} if $r->{format};
    }
    else {
        my %label=(post=>'Publication Reddit',comment=>'Commentaire Reddit',profile=>'Profil Reddit',community=>'Communauté Reddit',image=>'Image Reddit',video=>'Vidéo Reddit',share=>'Lien Reddit',link=>'Lien Reddit');
        $title=$label{$info->{kind}}//'Lien Reddit';
        push @meta,'r/'.$info->{subreddit} if $info->{subreddit};
        push @meta,'u/'.$info->{author} if $info->{author};
        push @meta,$r->{state} eq 'restricted'?'aperçu non accessible':$r->{state} eq 'busy'?'aperçu temporairement indisponible':'aperçu indisponible';
    }
    my $suffix=@meta ? ' · '.join(' · ',@meta) : '';
    # Metadata is bounded independently, leaving useful room for the title.
    while (@meta && _irc_wire_bytes($suffix)>180) {pop @meta;$suffix=@meta ? ' · '.join(' · ',@meta) : ''}
    my $budget=400-_irc_wire_bytes($prefix.$suffix)-3;
    my $text=_irc_prefix_for_budget($title,$budget);
    if (_irc_wire_bytes($title)>$budget) {$text=_irc_prefix_for_budget($title,$budget-3).'…'}
    return $prefix."\x02".$text."\x02".$suffix."\x0f";
}

sub handle {
    my ($bot,$message,$nick,$channel,$url)=@_;
    my $info=url_info($url);return 0 unless $info && enabled($bot,$channel);
    my $binding=capture_delivery_context($bot,$channel);my $epoch=epoch($bot,$channel);
    my $current=sub {delivery_context_current($bot,$binding) && epoch($bot,$channel)==$epoch && enabled($bot,$channel)};
    my $loop=eval {$bot->getLoop};$loop||=$bot->{loop};
    return 0 unless $loop && eval {$loop->can('add') && $loop->can('remove') && $loop->can('watch_process')};
    my $state=$bot->{_reddit_preview}//={cache=>{},pending=>{},recent=>{},starts=>[]};
    my $now=time;
    delete $state->{cache}{$_} for grep {$state->{cache}{$_}{until}<=$now} keys %{$state->{cache}};
    delete $state->{recent}{$_} for grep {$state->{recent}{$_}<=$now-300} keys %{$state->{recent}};
    my $request=lc($channel)."\0".$info->{key};
    return 1 if exists($state->{recent}{$request});
    return 0 if keys(%{$state->{recent}})>=512;
    my $send=sub {
        my ($result)=@_;return unless $current->();
        require Mediabot::Helpers;
        Mediabot::Helpers::botPrivmsg($bot,$channel,render($nick,$info,$result),{no_defer=>1});
    };
    if (my $cache=$state->{cache}{$info->{key}}) {$state->{recent}{$request}=$now;$send->($cache->{value});return 1}
    if (my $pending=$state->{pending}{$info->{key}}) {
        return 0 if @{$pending->{send}}>=16;
        push @{$pending->{send}},$send;$state->{recent}{$request}=$now;return 1;
    }
    if (($state->{blocked_until}//0)>$now) {$state->{recent}{$request}=$now;$send->({state=>'busy'});return 1}
    @{$state->{starts}}=grep {$_>$now-60} @{$state->{starts}};
    return 0 if keys(%{$state->{pending}})>=4 || @{$state->{starts}}>=12;
    push @{$state->{starts}},$now;$state->{recent}{$request}=$now;
    my $attempt={send=>[$send]};$state->{pending}{$info->{key}}=$attempt;my $done=0;
    my $complete=sub {
        my ($result)=@_;return if $done++;
        return unless $state->{pending}{$info->{key}} && refaddr($state->{pending}{$info->{key}})==refaddr($attempt);
        delete $state->{pending}{$info->{key}};
        my $value=_result(ref($result) eq 'HASH' && $result->{ok} ? $result->{value} : undef);
        $state->{blocked_until}=time+$value->{backoff} if $value->{backoff};
        $state->{cache}{$info->{key}}={until=>time+($value->{state} eq 'ok'?60:30),value=>$value};
        while (keys(%{$state->{cache}})>128) {my ($old)=sort {$state->{cache}{$a}{until}<=>$state->{cache}{$b}{until}} keys %{$state->{cache}};delete $state->{cache}{$old}}
        for my $recipient (@{$attempt->{send}}) {eval {$recipient->($value)}}
        $attempt->{send}=[];
    };
    my $worker=eval {Mediabot::AsyncWorker->start(loop=>$loop,label=>'Reddit preview',timeout=>30,max_output=>8192,
        child=>sub {
            eval {$bot->{dbh}{InactiveDestroy}=1 if $bot->{dbh}};
            eval {$bot->{db}{dbh}{InactiveDestroy}=1 if $bot->{db} && $bot->{db}{dbh}};
            return fetch($info->{url});
        },on_done=>$complete)};
    $complete->({ok=>0}) unless $worker || $done;
    return 1;
}
1;
