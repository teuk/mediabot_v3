package Mediabot::External::Wikipedia;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use Encode qw(decode encode FB_CROAK LEAVE_SRC);
use JSON::PP ();
use Mediabot::Helpers ();
use Mediabot::AsyncWorker ();
use Mediabot::External::URLCodec qw(_uri_escape_bytes);
use Mediabot::IRC::DeliveryContext qw(capture_delivery_context delivery_context_current);
use Mediabot::IRC::TextBudget qw(truncate_utf8 _irc_wire_bytes);

our @EXPORT_OK = qw(mbWikipedia_ctx);
our $MAX_PENDING = 2;
our $MAX_BODY = 128 * 1024;

sub _edition {
    my ($value) = @_;
    return 'en' unless defined($value) && !ref($value);
    $value =~ s/^\s+|\s+$//g;
    return lc($1) if $value =~ /\A([a-z]{2,3})(?:[-_][a-z0-9]+)*\z/i;
    return 'en';
}

sub _language {
    my ($bot, $channel) = @_;
    return _edition(eval { Mediabot::Helpers::channel_lang($bot, $channel) });
}

sub _query {
    my ($args) = @_;
    return unless ref($args) eq 'ARRAY' && @$args && @$args <= 32;
    return if grep { !defined($_) || ref($_) } @$args;
    my $text = join ' ', @$args;
    return if length($text) > 640;
    $text = eval { decode('UTF-8', $text, FB_CROAK | LEAVE_SRC) }
        unless utf8::is_utf8($text);
    return unless defined($text) && $text !~ /[\x00-\x1f\x7f]/;
    $text =~ s/\s+/ /g;
    $text =~ s/^\s+|\s+$//g;
    return unless length($text) && length($text) <= 160;
    my $bytes = eval { encode('UTF-8', $text, FB_CROAK | LEAVE_SRC) };
    return unless defined($bytes) && length($bytes) <= 320;
    return $text;
}

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
    my $bot = $ctx->bot;
    my $lang = _language($bot, $ctx->channel);
    my $args = $ctx->args;
    unless (ref($args) eq 'ARRAY' && @$args) {
        $ctx->reply_private(_message($lang, 'syntax'));
        return;
    }
    my $query = _query($args);
    unless (defined $query) {
        $ctx->reply_private(_message($lang, 'invalid'));
        return;
    }
    my $loop = eval { $bot->getLoop };
    $loop ||= $bot->{loop};
    unless ($loop && $loop->can('add') && $loop->can('remove')) {
        $ctx->reply_private(_message($lang, 'unavailable'));
        return;
    }
    my $pending = $bot->{_wikipedia_pending} //= {};
    if (keys(%$pending) >= $MAX_PENDING) {
        $ctx->reply_private(_message($lang, 'busy'));
        return;
    }
    my $id = ++$bot->{_wikipedia_sequence};
    $pending->{$id} = 1;
    my $binding = capture_delivery_context($bot, $ctx->channel);
    my $finished = 0;
    my $done = sub {
        my ($result) = @_;
        return if $finished++;
        delete $pending->{$id};
        return unless delivery_context_current($bot, $binding);
        my $message = _message($lang, 'unavailable');
        if (ref($result) eq 'HASH' && $result->{ok} && ref($result->{value}) eq 'HASH') {
            my $text = $result->{value}{message};
            $message = $text if defined($text) && !ref($text) && length($text)
                && $text !~ /[\x00-\x1f\x7f]/ && _irc_wire_bytes($text) <= 400;
        }
        my $sent = eval { $ctx->reply($message); 1 };
        eval { $bot->{logger}->log(1, 'Wikipedia reply failed') } if !$sent && $bot->{logger};
    };
    my $worker = eval { Mediabot::AsyncWorker->start(
        loop => $loop, label => 'wikipedia lookup', timeout => 12,
        term_grace => 0.2, force_grace => 1, max_output => 8192,
        child => sub { return {message => _lookup_sync($query, $lang)} },
        on_done => $done,
    ) };
    $done->({ok => 0, error => 'worker_setup'}) unless $worker;
    return 1;
}

1;
