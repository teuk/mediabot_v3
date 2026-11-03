package Mediabot::External::Wikipedia;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use JSON::PP ();
use Mediabot::External::URLCodec qw(_uri_escape_bytes);
use Mediabot::External::SearchCommand qw(_edition _language _query run_lookup);
use Mediabot::IRC::TextBudget qw(truncate_utf8 _irc_wire_bytes);

our @EXPORT_OK = qw(mbWikipedia_ctx);
our $MAX_BODY = 128 * 1024;

sub _message {
    my ($lang, $kind) = @_;
    my %messages = (
        syntax => ['Syntax: wikipedia <keyword>', 'Syntaxe : wikipedia <mot-clé>', 'Sintaxis: wikipedia <palabras clave>'],
        invalid => ['wikipedia: invalid or too long query.', 'wikipedia : recherche invalide ou trop longue.', 'wikipedia: búsqueda inválida o demasiado larga.'],
        busy => ['wikipedia: searches are busy; try again shortly.', 'wikipedia : recherches en cours, réessaie dans un instant.', 'wikipedia: búsquedas en curso; inténtalo de nuevo en un momento.'],
        unavailable => ['wikipedia: search temporarily unavailable.', 'wikipedia : recherche temporairement indisponible.', 'wikipedia: búsqueda temporalmente no disponible.'],
        missing => ['wikipedia: no article found.', 'wikipedia : aucun article trouvé.', 'wikipedia: no se encontró ningún artículo.'],
    );
    my $index = $lang eq 'fr' ? 1 : $lang eq 'es' ? 2 : 0;
    return $messages{$kind}[$index];
}

sub _plain {
    my ($text) = @_;
    return '' unless defined($text) && !ref($text);
    $text =~ s/[\x00-\x1f\x7f]/ /g;
    $text =~ s/\s+/ /g;
    $text =~ s/^\s+|\s+$//g;
    utf8::upgrade($text);
    return $text;
}

sub _result_message {
    my ($data, $lang) = @_;
    my $bad = _message($lang, 'unavailable');
    return $bad unless ref($data) eq 'HASH' && !exists($data->{error});
    return _message($lang, 'missing') if !exists($data->{query}) && $data->{batchcomplete};
    return $bad unless ref($data->{query}) eq 'HASH'
        && ref($data->{query}{pages}) eq 'ARRAY';
    my $pages = $data->{query}{pages};
    return _message($lang, 'missing') unless @$pages;
    return $bad unless @$pages == 1 && ref($pages->[0]) eq 'HASH';
    my $page = $pages->[0];
    return $bad unless defined($page->{pageid}) && !ref($page->{pageid})
        && $page->{pageid} =~ /\A[1-9][0-9]{0,19}\z/
        && defined($page->{ns}) && !ref($page->{ns}) && "$page->{ns}" eq '0';
    my $title = _plain($page->{title});
    return $bad unless length($title) && length($title) <= 512;
    my $extract = _plain($page->{extract});
    # Never follow or publish an arbitrary URL supplied in the API response.
    my $link = "https://$lang.wikipedia.org/?curid=$page->{pageid}";
    my $brand = $lang eq 'fr' ? 'Wikipédia' : 'Wikipedia';
    my $prefix = "[📚 $brand/$lang] " . truncate_utf8($title, 96, '…');
    my $suffix = " · $link";
    my $middle = '';
    if (length($extract)) {
        my $budget = 400 - _irc_wire_bytes($prefix . $suffix . ' — ');
        $middle = ' — ' . truncate_utf8($extract, $budget - 3, '…');
    }
    return $prefix . $middle . $suffix;
}

sub _lookup_sync {
    my ($query, $lang) = @_;
    $lang = _edition($lang);
    $query = _query([$query]);
    return _message($lang, 'invalid') unless defined $query;
    my $url = "https://$lang.wikipedia.org/w/api.php?action=query&format=json&formatversion=2"
        . '&generator=search&gsrnamespace=0&gsrlimit=1&prop=extracts&exintro=1'
        . '&explaintext=1&exchars=600&exlimit=1&redirects=1&gsrsearch=' . _uri_escape_bytes($query);
    require Mediabot::External;
    my $http = Mediabot::External::_make_http(
        timeout => 8, verify_SSL => 1, max_size => $MAX_BODY, max_redirect => 0,
        agent => 'Mediabot/3.8dev (https://github.com/teuk/mediabot_v3; Wikipedia lookup)',
    );
    my $response = eval { $http->get($url, {headers => {Accept => 'application/json'}}) };
    return _message($lang, 'unavailable') unless ref($response) eq 'HASH' && $response->{success}
        && defined($response->{content}) && !ref($response->{content})
        && _irc_wire_bytes($response->{content}) <= $MAX_BODY;
    my $data = eval { JSON::PP::decode_json($response->{content}) };
    return _message($lang, 'unavailable') if $@;
    return _result_message($data, $lang);
}

sub mbWikipedia_ctx {
    my ($ctx) = @_;
    return run_lookup($ctx, name=>'Wikipedia', label=>'wikipedia lookup',
        message=>\&_message,
        lookup=>sub {return {message=>_lookup_sync(@_)}},
        render=>sub {
            my ($value)=@_;my $text=$value->{message};
            return unless defined($text) && !ref($text) && $text !~ /[\x00-\x1f\x7f]/;
            return [$text];
        });
}

1;
