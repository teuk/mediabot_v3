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

our @EXPORT_OK=qw(mbDDG_ctx);
our $MAX_BODY=256*1024;
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
    return _target($href);
}
sub _class { return (($_[0]->attr('class')//'') =~ /(?:\A|\s)\Q$_[1]\E(?:\s|\z)/) }
sub _parse {
    my ($html)=@_;return {state=>'unavailable'} unless defined($html) && !ref($html) && _irc_wire_bytes($html)<=$MAX_BODY;
    $html=eval {decode('UTF-8',$html,FB_CROAK|LEAVE_SRC)} unless utf8::is_utf8($html);
    return {state=>'unavailable'} unless defined $html;
    # Challenge pages are failures, never "no results" or a reason to bypass them.
    return {state=>'unavailable'} if $html =~ /anomaly\.js|anomaly-modal|challenge-form|captcha/i;
    my $tree=HTML::TreeBuilder->new;my (@hits,%seen);my $missing=0;
    my $ok=eval {
        $tree->parse_content($html);
        $missing=$tree->look_down(sub {_class($_[0],'no-results') || _class($_[0],'no-results__message')}) ? 1:0;
        for my $link ($tree->look_down(_tag=>'a')) {
            next unless _class($link,'result__a') || _class($link,'result-link');
            my $ad=0;my $container=$link;
            while (my $parent=$container->parent) {
                $container=$parent;
                $ad=1 if _class($parent,'result--ad') || _class($parent,'result--ad--small');
                last if _class($parent,'result') || $parent->tag eq 'body';
            }
            next if $ad;
            my $url=_result_url($link->attr('href'));my $title=_plain($link->as_text,512);
            next unless $url && length($title) && !$seen{$url}++;
            my $snippet=$container->look_down(sub {_class($_[0],'result__snippet')});
            push @hits,{url=>$url,title=>$title,excerpt=>$snippet?_plain($snippet->as_text,800):''};
            last if @hits>=2;
        }
        1;
    };
    $tree->delete;
    return {state=>'unavailable'} unless $ok;
    return @hits ? {state=>'ok',hits=>\@hits} : {state=>$missing?'missing':'unavailable'};
}
sub _search_url { return 'https://duckduckgo.com/?q='._uri_escape_bytes($_[0]) }
sub _lookup_sync {
    my ($bot,$query,$lang)=@_;$lang=_edition($lang);$query=_query([$query]);
    return {state=>'unavailable'} unless defined $query;
    my %region=(fr=>'fr-fr',es=>'es-es',en=>'wt-wt',de=>'de-de',pt=>'pt-pt',it=>'it-it',nl=>'nl-nl');
    my $url='https://html.duckduckgo.com/html/?q='._uri_escape_bytes($query).'&kl='.($region{$lang}//'wt-wt');
    require Mediabot::External;
    my $http=Mediabot::External::_make_http(timeout=>8,verify_SSL=>1,max_size=>$MAX_BODY,max_redirect=>0,
        agent=>'Mediabot/3.8dev (https://github.com/teuk/mediabot_v3; web search)');
    my $response=eval {$http->get($url,{headers=>{Accept=>'text/html'}})};
    my $value=ref($response) eq 'HASH' && $response->{success} && ($response->{status}//0)==200
        ? _parse($response->{content}) : {state=>'unavailable'};
    if ($value->{state} eq 'unavailable') {
        $value={state=>'ok',fallback=>1,hits=>[{title=>'DuckDuckGo',excerpt=>_message($lang,'unavailable'),url=>_search_url($query)}]};
    }
    if ($value->{state} eq 'ok') {
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
sub _render {
    my ($value,$lang,$base)=@_;
    return [_message($lang,'missing')] if defined($value->{state}) && !ref($value->{state}) && $value->{state} eq 'missing';
    return unless defined($value->{state}) && !ref($value->{state}) && $value->{state} eq 'ok'
        && ref($value->{hits}) eq 'ARRAY' && @{$value->{hits}} && @{$value->{hits}}<=2;
    $base=Mediabot::URLShortener::_public_base($base);my @lines;my $rank=0;
    for my $hit (@{$value->{hits}}) {
        return unless ref($hit) eq 'HASH';my $url=_target($hit->{url});my $display=_target($hit->{display_url})//$url;
        return unless $url && $display && ($display eq $url || (length($base) && $display =~ m{\A\Q$base\E[23456789A-HJ-NP-Za-km-z]{8,16}\z}));
        my $title=_plain($hit->{title},512);return unless length $title;
        my $badge="\x0300,02[🦆 DDG]\x0f ";my $link="\x0312\x1f$display\x1f\x0f";
        if (_irc_wire_bytes($link)>280) {push @lines,$badge._message($lang,'long');next}
        my $suffix=" \x0314·\x0f $link";
        my $lead=$badge.(++$rank).'. ';
        my $title_budget=400-_irc_wire_bytes($lead.$suffix."\x02\x02")-3;
        $title_budget=80 if $title_budget>80;
        my $prefix=$lead."\x02".truncate_utf8($title,$title_budget,'…')."\x02";
        my $excerpt=_plain($hit->{excerpt},800);my $middle='';
        my $budget=400-_irc_wire_bytes($prefix.$suffix.' — ')-3;
        $middle=' — '.truncate_utf8($excerpt,$budget,'…') if length($excerpt) && $budget>=16;
        push @lines,$prefix.$middle.$suffix;
    }
    return \@lines;
}
sub mbDDG_ctx {
    my ($ctx)=@_;my $base=eval {$ctx->bot->{conf}->get('shorturl.PUBLIC_BASE_URL')} // '';
    return run_lookup($ctx,name=>'ddg',label=>'ddg search',timeout=>16,max_output=>16384,
        message=>\&_message,lookup=>sub {_lookup_sync($ctx->bot,@_)},render=>sub {_render(@_,$base)});
}

1;
