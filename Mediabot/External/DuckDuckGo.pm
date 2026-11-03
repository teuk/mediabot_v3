package Mediabot::External::DuckDuckGo;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use Encode qw(decode FB_CROAK LEAVE_SRC);
use HTML::TreeBuilder;
use URI ();
use URI::Escape qw(uri_unescape);
use Mediabot::External::URLCodec qw(_uri_escape_bytes);
use Mediabot::External::SearchCommand qw(_edition _query run_lookup);
use Mediabot::IRC::TextBudget qw(_irc_wire_bytes truncate_utf8);
use Mediabot::URLShortener qw(make_bot_shortener);
use Mediabot::JSON qw(decode_json_payload);

our @EXPORT_OK=qw(mbDDG_ctx);
our $MAX_BODY=256*1024;
our $MAX_DOM=2*1024*1024;
use constant MAX_RESULTS => 3;
sub _message {
    my ($lang,$kind)=@_;
    my %text=(
        syntax=>['Syntax: ddg <keywords>','Syntaxe : ddg <mots-clés>','Sintaxis: ddg <palabras clave>'],
        invalid=>['ddg: invalid or too long query.','ddg : recherche invalide ou trop longue.','ddg: búsqueda inválida o demasiado larga.'],
        busy=>['ddg: searches are busy; try again shortly.','ddg : recherches en cours, réessaie dans un instant.','ddg: búsquedas en curso; inténtalo de nuevo en un momento.'],
        unavailable=>['ddg: results temporarily unavailable.','ddg : résultats temporairement indisponibles.','ddg: resultados temporalmente no disponibles.'],
        missing=>['ddg: no results found.','ddg : aucun résultat trouvé.','ddg: no se encontraron resultados.'],
        long=>['ddg: link too long; URL shortener unavailable.','ddg : lien trop long, raccourcisseur indisponible.','ddg: enlace demasiado largo; acortador no disponible.'],
    );
    return $text{$kind}[$lang eq 'fr'?1:$lang eq 'es'?2:0];
}
sub _plain {
    my ($text,$max)=@_;return '' unless defined($text) && !ref($text);
    $text=substr($text,0,$max//1200);
    $text =~ s/\x03[0-9]{0,2}(?:,[0-9]{1,2})?//g;
    $text =~ s/[\x00-\x1f\x7f-\x9f\x{200e}\x{200f}\x{202a}-\x{202e}\x{2066}-\x{2069}\x{feff}]/ /g;
    $text =~ s/\s+/ /g;$text =~ s/^\s+|\s+$//g;utf8::upgrade($text);return $text;
}
sub _target {
    my ($url)=@_;
    return unless defined($url) && !ref($url) && length($url)<=2048 && $url !~ /[\x00-\x20\x7f\\]/;
    my $u=eval {URI->new($url)};
    return unless $u && ($u->scheme//'') =~ /\Ahttps?\z/i && !defined($u->userinfo);
    my $host=eval {$u->host};my $port=eval {$u->port};
    return unless defined($host) && $host =~ /\A[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\z/i
        && defined($port) && "$port" =~ /\A[0-9]{1,5}\z/ && $port>0 && $port<=65535;
    my $out=$u->as_string;
    return unless length($out)<=2048 && $out =~ /\A[\x21-\x7e]+\z/;
    return $out;
}
sub _destination {
    my $url=_target($_[0]);return unless $url;
    my $uri=URI->new($url);
    if ($uri->host =~ /(?:\A|\.)duckduckgo\.com\z/i) {
        my @query=$uri->query_form;
        return if grep {lc($query[$_]) =~ /\A(?:q|ad_domain|ad_provider)\z/} grep {$_%2==0} 0..$#query;
        return if uri_unescape($uri->path) =~ m{\A/(?:html|lite|c|l|y(?:\.js)?)(?:/|\z)}i;
    }
    return if $uri->host =~ /(?:\A|\.)bing\.com\z/i && uri_unescape($uri->path) =~ m{\A/aclick(?:/|\z)}i;
    return $url;
}
sub _result_url {
    my ($href)=@_;return unless defined($href) && !ref($href);
    # Unwrap only an actual DDG redirect, and exactly one encoded target.
    if ($href =~ m{\A(?:(?:https?:)?//(?:(?:www|lite|html)\.)?duckduckgo\.com)?/l/\?([^#]*)(?:#.*)?\z}i) {
        my @targets;
        for my $part (split /&/,$1) {
            my ($key,$value)=split /=/,$part,2;
            push @targets,uri_unescape($value//'') if defined($key) && lc(uri_unescape($key)) eq 'uddg';
        }
        return unless @targets==1;
        $href=$targets[0];
    }
    return _destination($href);
}
sub _class { return (($_[0]->attr('class')//'') =~ /(?:\A|\s)\Q$_[1]\E(?:\s|\z)/) }
sub _is_title {
    my ($node)=@_;
    return $node->tag eq 'a' && (($node->attr('data-testid')//'') eq 'result-title-a'
        || _class($node,'result__a') || _class($node,'result-link'));
}
sub _is_snippet {
    my ($node)=@_;
    return ($node->attr('data-result')//'') eq 'snippet'
        || ($node->attr('data-testid')//'') eq 'result-snippet'
        || _class($node,'result__snippet') || _class($node,'result-snippet');
}
sub _ad_marker {
    my ($node)=@_;
    return _class($node,'result--ad') || _class($node,'result--ad--small')
        || ($node->attr('data-testid')//'') =~ /\A(?:ad(?:s|-.*)?|result-ad|sponsored-result)\z/i
        || ($node->attr('data-layout')//'') =~ /\A(?:ad|ads|sponsored)\z/i;
}
sub _owned_snippet {
    my ($link)=@_;
    my $key=_result_url($link->attr('href')) // ($link->attr('href')//'');
    # Opaque modern cards need no CSS wrapper name. Never cross another
    # result's title, even if that other link is an ad or an invalid URL.
    for (my $node=$link->parent; $node && $node->tag !~ /\A(?:body|html)\z/; $node=$node->parent) {
        return if _ad_marker($node);
        my %owners;
        for my $title ($node->look_down(\&_is_title)) {
            $owners{_result_url($title->attr('href')) // ($title->attr('href')//'')}=1;
        }
        return if grep {$_ ne $key} keys %owners;
        for my $snippet ($node->look_down(\&_is_snippet)) {
            my $text=_plain($snippet->as_text,800);
            return $text if length $text;
        }
    }
    return;
}
sub _parse {
    my ($html,%opts)=@_;
    my $limit=$opts{rendered}?$MAX_DOM:$MAX_BODY;
    return {state=>'unavailable'} unless defined($html) && !ref($html) && _irc_wire_bytes($html)<$limit;
    $html=eval {decode('UTF-8',$html,FB_CROAK|LEAVE_SRC)} unless utf8::is_utf8($html);
    return {state=>'unavailable'} unless defined $html;
    my $tree=HTML::TreeBuilder->new;my (@hits,%seen);my ($missing,$challenge)=(0,0);
    my $ok=eval {
        $tree->parse_content($html);
        # Inspect actual verification nodes; normal scripts and snippets may
        # contain words such as captcha without being a challenge page.
        $challenge=$tree->look_down(sub {
            _class($_[0],'anomaly-modal') || ($_[0]->attr('id')//'') =~ /\A(?:challenge-form|anomaly-modal)\z/
                || ($_[0]->tag eq 'form' && ($_[0]->attr('action')//'') =~ m{(?:/|\A)anomaly(?:\.js|/|\z)})
        })?1:0;
        $missing=$tree->look_down(sub {_class($_[0],'no-results') || _class($_[0],'no-results__message')}) ? 1:0;
        unless ($challenge) {
            for my $link ($tree->look_down(\&_is_title)) {
                my $url=_result_url($link->attr('href'));my $title=_plain($link->as_text,512);
                next unless $url && length($title) && !$seen{$url};
                my $ad=0;
                for (my $node=$link; $node && $node->tag ne 'body'; $node=$node->parent) {$ad=1 if _ad_marker($node)}
                next if $ad;
                my $excerpt=_owned_snippet($link);
                next unless defined($excerpt) && length($excerpt);
                $seen{$url}=1;
                push @hits,{url=>$url,title=>$title,excerpt=>$excerpt};
                last if @hits>=MAX_RESULTS;
            }
        }
        1;
    };
    $tree->delete;
    return {state=>'unavailable'} unless $ok && !$challenge;
    return @hits ? {state=>'ok',hits=>\@hits} : {state=>$missing?'missing':'unavailable'};
}
sub _region {
    my %region=(fr=>'fr-fr',es=>'es-es',en=>'wt-wt',de=>'de-de',pt=>'pt-pt',it=>'it-it',nl=>'nl-nl');
    return $region{_edition($_[0])}//'wt-wt';
}
sub _instant_preview {
    my ($query,$lang)=@_;$query=_query([$query]);$lang=_edition($lang);
    return unless defined $query;
    my $url='https://api.duckduckgo.com/?q='._uri_escape_bytes($query)
        .'&format=json&no_html=1&no_redirect=1&skip_disambig=1&kl='._region($lang);
    require Mediabot::External;
    my $http=eval {Mediabot::External::_make_http(timeout=>8,verify_SSL=>1,max_size=>128*1024,max_redirect=>0,
        agent=>'Mediabot/3.8dev (https://github.com/teuk/mediabot_v3; search preview)')};
    return unless $http;
    my $response=eval {$http->get($url,{headers=>{Accept=>'application/json','Accept-Language'=>$lang}})};
    return unless ref($response) eq 'HASH' && $response->{success}
        && defined($response->{status}) && !ref($response->{status}) && "$response->{status}" =~ /\A2[0-9]{2}\z/
        && defined($response->{content}) && !ref($response->{content}) && _irc_wire_bytes($response->{content})<=128*1024;
    my $data=eval {decode_json_payload($response->{content})};
    return unless ref($data) eq 'HASH';
    my $title=_plain($data->{Heading},512);my $excerpt=_plain($data->{AbstractText},800);
    my $source=_destination($data->{AbstractURL});
    return unless length($title) && length($excerpt) && $source;
    # Instant-answer abstracts are previews, never ranked web search hits.
    # Ignore Redirect, HTML Answer/Abstract and broad RelatedTopics categories.
    return {title=>$title,excerpt=>$excerpt,url=>$source};
}
sub _browser_lookup {
    my ($bot,$query,$lang)=@_;
    require Mediabot::External::Chromium;
    my %locale=(fr=>'fr-FR',en=>'en-US',es=>'es-ES',de=>'de-DE',pt=>'pt-PT',it=>'it-IT',nl=>'nl-NL');
    my $cancelled=0;
    # Let the bounded native helper reap its browser normally on cancellation.
    # The worker's TERM grace covers its 15s deadline plus native cleanup.
    local $SIG{TERM}=sub {$cancelled=1};
    my $dom=eval {Mediabot::External::Chromium::_fetch_url_chromium_dumpdom($bot,
        'https://duckduckgo.com/?q='._uri_escape_bytes($query).'&ia=web&kl='._region($lang),
        virtual_time_budget=>7000,alarm_timeout=>15,lang=>$locale{$lang}//$lang,
        max_stdout=>$MAX_DOM,max_stderr=>32768)};
    return {state=>'cancelled'} if $cancelled;
    return _parse($dom,rendered=>1);
}
sub _lookup_sync {
    my ($bot,$query,$lang)=@_;$lang=_edition($lang);$query=_query([$query]);
    return {state=>'unavailable'} unless defined $query;
    my $url='https://html.duckduckgo.com/html/?q='._uri_escape_bytes($query).'&kl='._region($lang);
    require Mediabot::External;
    my $http=Mediabot::External::_make_http(timeout=>8,verify_SSL=>1,max_size=>$MAX_BODY,max_redirect=>0,
        agent=>'Mediabot/3.8dev (https://github.com/teuk/mediabot_v3; web search)');
    my $response=eval {$http->get($url,{headers=>{Accept=>'text/html'}})};
    my $value=ref($response) eq 'HASH' && $response->{success} && ($response->{status}//0)==200
        ? _parse($response->{content}) : {state=>'unavailable'};
    $value->{source}='html' if $value->{state} eq 'ok';
    if ($value->{state} eq 'unavailable' || ($value->{state} eq 'ok' && @{$value->{hits}}<MAX_RESULTS)) {
        my $browser=eval {_browser_lookup($bot,$query,$lang)};
        return $browser if ref($browser) eq 'HASH' && ($browser->{state}//'') eq 'cancelled';
        if (ref($browser) eq 'HASH' && ($browser->{state}//'') eq 'ok'
            && @{$browser->{hits}} > scalar(@{$value->{hits}//[]})) {
            $value=$browser;$value->{source}='chromium';
        }
    }
    if ($value->{state} eq 'unavailable') {
        my $preview=eval {_instant_preview($query,$lang)};
        $value=$preview ? {state=>'preview',source=>'instant',hits=>[$preview]} : {state=>'unavailable'};
    }
    if ($value->{state} eq 'ok' || $value->{state} eq 'preview') {
        # Private shortener credentials and all shortening I/O stay in the child.
        my $shorten=make_bot_shortener(bot=>$bot,allow_legacy=>0);
        my $base=eval {$bot->{conf}->get('shorturl.PUBLIC_BASE_URL')} // '';
        $base=Mediabot::URLShortener::_public_base($base);
        for my $hit (@{$value->{hits}}) {
            my $short=eval {$shorten->($hit->{url})};
            $hit->{display_url}=defined($short) && !ref($short) && _target($short)
                && ($short eq $hit->{url} || (length($base) && $short =~ m{\A\Q$base\E[23456789A-HJ-NP-Za-km-z]{8,16}\z}))
                ? $short : $hit->{url};
        }
    }
    return $value;
}
sub _display_url {
    my ($hit,$base)=@_;
    return unless ref($hit) eq 'HASH';
    my $url=_destination($hit->{url});my $display=_target($hit->{display_url})//$url;
    return unless $url && $display && ($display eq $url || (length($base)
        && $display =~ m{\A\Q$base\E[23456789A-HJ-NP-Za-km-z]{8,16}\z}));
    return $display;
}
sub _badge { return "\x0300,02[🦆 DDG]\x0f " }
sub _link { return "\x0312\x1f$_[0]\x1f\x0f" }
sub _render {
    my ($value,$lang,$base)=@_;
    return unless ref($value) eq 'HASH' && defined($value->{state}) && !ref($value->{state});
    return [_message($lang,'missing')] if $value->{state} eq 'missing';
    my $preview=$value->{state} eq 'preview';
    return unless ($value->{state} eq 'ok' || $preview)
        && ref($value->{hits}) eq 'ARRAY' && @{$value->{hits}} && @{$value->{hits}}<=MAX_RESULTS;
    return if $preview && @{$value->{hits}}!=1;
    $base=Mediabot::URLShortener::_public_base($base);
    my (@lines,%seen);my $rank=0;
    for my $hit (@{$value->{hits}}) {
        my $display=_display_url($hit,$base);return unless $display && !$seen{$hit->{url}}++;
        my $title=_plain($hit->{title},512);my $excerpt=_plain($hit->{excerpt},800);
        return unless length($title) && length($excerpt);
        my $lead=$preview?'':(++$rank).'. ';
        my $suffix=" \x0314·\x0f "._link($display);
        my $room=400-_irc_wire_bytes(_badge().$lead.$suffix."\x02\x02 — ")-3;
        if ($room<32) {push @lines,_badge().$lead._message($lang,'long');next}
        my $title_budget=$room-24;$title_budget=80 if $title_budget>80;
        my $prefix=_badge().$lead."\x02".truncate_utf8($title,$title_budget,'…')."\x02 — ";
        my $budget=400-_irc_wire_bytes($prefix.$suffix)-3;
        push @lines,$prefix.truncate_utf8($excerpt,$budget,'…').$suffix;
    }
    return \@lines;
}
sub mbDDG_ctx {
    my ($ctx)=@_;my $base=eval {$ctx->bot->{conf}->get('shorturl.PUBLIC_BASE_URL')} // '';
    return run_lookup($ctx,name=>'ddg',label=>'ddg search',timeout=>40,term_grace=>18,force_grace=>19,max_output=>32768,
        message=>\&_message,lookup=>sub {_lookup_sync($ctx->bot,@_)},render=>sub {_render(@_,$base)});
}

1;
