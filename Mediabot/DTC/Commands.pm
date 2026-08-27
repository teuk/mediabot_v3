package Mediabot::DTC::Commands;

use strict;
use warnings;
use utf8;

use Encode qw(encode);

use Mediabot::DTC::Source qw(fetch_random fetch_by_id search_ids);
use Mediabot::CommandAsync ();
use Mediabot::Helpers ();

use constant CHANSET_NAME       => 'DansTonChat';
use constant MAX_LINES          => 10;
use constant MAX_SEARCH_RESULTS => 5;
use constant MAX_WIRE_BYTES     => 430;

sub chanset_name { return CHANSET_NAME }

sub _clean_line {
    my ($line) = @_;
    return '' unless defined($line) && !ref($line);
    $line =~ s/[\r\n\0]+/ /g;
    $line =~ s/^\s+|\s+$//g;
    return $line;
}

sub _fit_wire {
    my ($line) = @_;
    return '' unless defined($line) && !ref($line);
    return $line if length(encode('UTF-8', $line)) <= MAX_WIRE_BYTES;
    my $suffix = "\x{2026}\x0f";
    while (length($line) && length(encode('UTF-8', $line . $suffix)) > MAX_WIRE_BYTES) {
        chop $line;
    }
    return $line . $suffix;
}

sub format_quote_lines {
    my ($id, $text) = @_;
    $id = '??' unless defined($id) && !ref($id) && $id =~ /\A(?:[0-9]+|\?\?)\z/;
    return [] unless defined($text) && !ref($text);

    my @lines = grep { length($_) } map { _clean_line($_) } split /\n/, $text;
    return [] unless @lines;

    if (@lines > MAX_LINES) {
        my $url = $id =~ /\A[0-9]+\z/
            ? "Consultez la quote ici : https://danstonchat.com/quote/$id.html"
            : undef;
        my $keep = MAX_LINES - ($url ? 2 : 1);
        $keep = 1 if $keep < 1;
        @lines = (@lines[0 .. $keep - 1], '...');
        push @lines, $url if $url;
    }

    my @out;
    my $first = shift @lines;
    push @out, _fit_wire("\x03" . '01,15' . "\x02[$id]\x02\x03" . '00,14' . " $first\x0f");
    for my $line (@lines) {
        push @out, _fit_wire("\x03" . '00,14' . "$line\x0f");
    }
    return \@out;
}

sub format_search_header {
    my ($ids) = @_;
    return undef unless ref($ids) eq 'ARRAY' && @$ids;
    my @safe = grep { defined($_) && !ref($_) && /\A[0-9]+\z/ } @$ids;
    splice(@safe, MAX_SEARCH_RESULTS) if @safe > MAX_SEARCH_RESULTS;
    return undef unless @safe;
    return "\x03" . '01,15' . '[DansTonChat : ' . join('|', @safe) . "]\x0f";
}

sub _send_quote {
    my ($bot, $channel, $id, $text) = @_;
    my $lines = format_quote_lines($id, $text);
    return 0 unless @$lines;
    Mediabot::Helpers::botPrivmsg($bot, $channel, $_) for @$lines;
    return scalar @$lines;
}

sub _run_ctx {
    my ($ctx) = @_;
    return 0 unless $ctx && eval { $ctx->can('bot') } && eval { $ctx->can('channel') };
    my $bot = $ctx->bot or return 0;
    my $channel = $ctx->channel;
    my $nick = eval { $ctx->nick } // '';
    my @args = ref($ctx->args) eq 'ARRAY' ? @{ $ctx->args } : ();
    my $arg = join(' ', @args);
    $arg =~ s/^\s+|\s+$//g;

    if ($arg eq '') {
        my $res = fetch_random();
        unless ($res->{ok}) {
            Mediabot::Helpers::botPrivmsg($bot, $channel,
                "D\x{00e9}sol\x{00e9}, aucune quote al\x{00e9}atoire disponible pour le moment.");
            return 1;
        }
        _send_quote($bot, $channel, $res->{id}, $res->{text});
        return 1;
    }

    if ($arg =~ /\A\s*\(?\s*([0-9]+)\s*\)?\s*\z/) {
        my $id = $1;
        my $res = fetch_by_id($id);
        unless ($res->{ok}) {
            Mediabot::Helpers::botPrivmsg($bot, $channel,
                "D\x{00e9}sol\x{00e9}, je n'ai pas trouv\x{00e9} la quote #$id.");
            return 1;
        }
        _send_quote($bot, $channel, $res->{id}, $res->{text});
        return 1;
    }

    my $search = search_ids($arg);
    my $ids = $search->{ok} && ref($search->{ids}) eq 'ARRAY' ? $search->{ids} : [];
    unless (@$ids) {
        Mediabot::Helpers::botPrivmsg($bot, $channel, "Aucun r\x{00e9}sultat pour \x{00ab} $arg \x{00bb}.");
        return 1;
    }

    my $header = format_search_header($ids);
    Mediabot::Helpers::botPrivmsg($bot, $channel, $header) if defined $header;

    my $id = $ids->[0];
    my $res = fetch_by_id($id);
    if ($res->{ok}) {
        _send_quote($bot, $channel, $res->{id}, $res->{text});
    }
    else {
        Mediabot::Helpers::botPrivmsg($bot, $channel,
            "D\x{00e9}sol\x{00e9}, impossible d'afficher la quote #$id.");
    }
    return 1;
}

sub dispatch_ctx {
    my ($ctx) = @_;
    return 0 unless $ctx && eval { $ctx->can('bot') } && eval { $ctx->can('channel') };
    my $bot = $ctx->bot or return 0;
    my $channel = $ctx->channel;
    my $nick = eval { $ctx->nick } // '';

    unless (defined($channel) && !ref($channel) && $channel =~ /^#/) {
        Mediabot::Helpers::botNotice($bot, $nick, 'DansTonChat is available only from a channel.');
        return 1;
    }

    my $enabled = eval {
        Mediabot::Helpers::chanset_enabled($bot, $channel, CHANSET_NAME, default => 0)
    } ? 1 : 0;
    unless ($enabled) {
        Mediabot::Helpers::botPrivmsg($bot, $channel,
            'Activez +DansTonChat pour !dtc / !bashfr.');
        return 1;
    }

    return Mediabot::CommandAsync::run_ctx_async(
        $bot, $ctx, 'dtc', sub { _run_ctx($ctx) }
    );
}

1;
