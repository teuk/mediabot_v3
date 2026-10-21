package Mediabot::IRC::Presentation;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use Mediabot::IRC::TextBudget qw(_irc_wire_bytes);

our @EXPORT_OK = qw(format_reply _wire_bytes _decode_entity _markdown_to_irc _style_after _balanced_line _plain_suffix format_ai_reply IRC_BOLD IRC_RESET IRC_ITALIC IRC_UNDERLINE MAX_IRC_LINES MAX_IRC_BYTES);

use constant {
    IRC_BOLD      => "\x02",
    IRC_RESET     => "\x0f",
    IRC_ITALIC    => "\x1d",
    IRC_UNDERLINE => "\x1f",
    MAX_IRC_LINES => 2,
    MAX_IRC_BYTES => 400,
};

sub _wire_bytes {
    return _irc_wire_bytes(@_);
}

sub _decode_entity {
    my ($entity) = @_;
    return '&'  if lc($entity) eq 'amp';
    return '<'  if lc($entity) eq 'lt';
    return '>'  if lc($entity) eq 'gt';
    return '"'  if lc($entity) eq 'quot';
    return "'"  if lc($entity) eq 'apos' || $entity eq '#39';
    return ' '  if lc($entity) eq 'nbsp';

    my $value;
    if ($entity =~ /\A#x([0-9a-f]+)\z/i) {
        $value = hex($1);
    }
    elsif ($entity =~ /\A#(\d+)\z/) {
        $value = int($1);
    }

    return "&$entity;"
        unless defined($value)
            && $value >= 0
            && $value <= 0x10ffff
            && !($value >= 0xd800 && $value <= 0xdfff);

    return chr($value);
}

sub _markdown_to_irc {
    my ($text) = @_;
    return '' unless defined($text) && !ref($text);

    $text =~ s/\A\x{feff}//;
    $text =~ s/\r\n?/\n/g;

    # Provider output is untrusted IRC input. Remove any pre-existing colour
    # or control sequence before creating the three styles allowed here.
    $text =~ s/\x03\d{0,2}(?:,\d{1,2})?//g;
    $text =~ s/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]//g;

    my @literal;
    $text =~ s{\\([\\`*_{}\[\]()#+.!>|~\-])}{
        my $slot = scalar @literal;
        push @literal, $1;
        "\x{f0000}$slot\x{f0001}";
    }gex;

    $text =~ s{<br\s*/?>}{\n}ig;
    $text =~ s{</?(?:strong|b)\b[^>]*>}{IRC_BOLD}ige;
    $text =~ s{</?(?:em|i)\b[^>]*>}{IRC_ITALIC}ige;
    $text =~ s{</?u\b[^>]*>}{IRC_UNDERLINE}ige;
    $text =~ s{</?(?:code|pre)\b[^>]*>}{}ig;
    $text =~ s{<(https?://[^>\s]+)>}{$1}gi;
    $text =~ s{</?[a-z][^>]*>}{}ig;
    $text =~ s/&([a-z]+|#\d+|#x[0-9a-f]+);/_decode_entity($1)/ige;

    # Fences carry no useful presentation on IRC; retain their contents.
    $text =~ s/^\s*```[^\n]*$//mg;
    $text =~ s/`{1,3}([^`\n]+)`{1,3}/$1/g;

    $text =~ s{!\[([^\]\n]*)\]\((https?://[^\s)]+)(?:\s+"[^"]*")?\)}{
        length($1) ? "$1 <$2>" : $2;
    }gei;
    $text =~ s{\[([^\]\n]+)\]\((https?://[^\s)]+)(?:\s+"[^"]*")?\)}{
        $1 eq $2 ? $2 : "$1 <$2>";
    }gei;

    my @parts;
    my $paragraph_break = 0;
    my $previous_kind = '';

    for my $line (split /\n/, $text, -1) {
        $line =~ s/^\s+|\s+$//g;
        if ($line eq '') {
            $paragraph_break = 1 if @parts;
            next;
        }

        next if $line =~ /\A(?:-{3,}|_{3,}|\*{3,})\z/;

        my $kind = 'text';
        if ($line =~ s/\A#{1,6}\s+//) {
            $line =~ s/\s+#+\z//;
            $line = IRC_BOLD . IRC_UNDERLINE . $line
                  . IRC_UNDERLINE . IRC_BOLD;
            $kind = 'heading';
        }
        elsif ($line =~ s/\A>\s*//) {
            $line = IRC_ITALIC . $line . IRC_ITALIC;
            $kind = 'quote';
        }
        elsif ($line =~ s/\A[-+*]\s+/\x{2022} /) {
            $kind = 'list';
        }
        elsif ($line =~ /\A\d+[.)]\s+/) {
            $kind = 'list';
        }
        elsif ($line =~ /^\|.*\|$/) {
            $line =~ s/^\|\s*|\s*\|$//g;
            $line =~ s/\s*\|\s*/ \x{b7} /g;
            next if $line =~ /\A(?:\s*:?-+:?\s*)(?:\x{b7}\s*:?-+:?\s*)*\z/;
            $kind = 'table';
        }

        if (@parts) {
            push @parts,
                ($paragraph_break
                    || $kind eq 'list'
                    || $kind eq 'table'
                    || $previous_kind eq 'list'
                    || $previous_kind eq 'table'
                    || $kind eq 'heading')
                ? " \x{b7} "
                : ' ';
        }
        push @parts, $line;
        $paragraph_break = 0;
        $previous_kind = $kind;
    }

    $text = join '', @parts;

    # Strong is evaluated first so ***nested emphasis*** becomes bold+italic.
    $text =~ s/\*\*\s*(?=\S)(.+?\S)\s*\*\*/IRC_BOLD . $1 . IRC_BOLD/gse;
    $text =~ s/(?<![\w_])__\s*(?=\S)(.+?\S)\s*__(?![\w_])/IRC_BOLD . $1 . IRC_BOLD/gse;
    $text =~ s/(?<!\*)\*(?=\S)(.+?\S)\*(?!\*)/IRC_ITALIC . $1 . IRC_ITALIC/gse;
    $text =~ s/(?<![\w_])_(?=\S)(.+?\S)_(?![\w_])/IRC_ITALIC . $1 . IRC_ITALIC/gse;
    $text =~ s/\+\+(?=\S)(.+?\S)\+\+/IRC_UNDERLINE . $1 . IRC_UNDERLINE/gse;
    $text =~ s/~~(?=\S)(.+?\S)~~/$1/gs;

    $text =~ s/\x{f0000}(\d+)\x{f0001}/
        defined($literal[$1]) ? $literal[$1] : ''
    /gex;

    # Remove unsupported Markdown scaffolding that survived malformed input.
    $text =~ s/`+//g;
    $text =~ s/\*\*|__|~~//g;
    $text =~ s/[\t ]+/ /g;
    $text =~ s/^\s+|\s+$//g;

    # Defence in depth: only printable text plus bold, reset, italic and
    # underline can leave this boundary.
    $text =~ s/[\x00-\x01\x03-\x0e\x10-\x1c\x1e\x7f]//g;
    return $text;
}

sub _style_after {
    my ($text, $incoming) = @_;
    my %state = %{ $incoming || {} };

    for my $char (split //, ($text // '')) {
        if ($char eq IRC_RESET) {
            %state = (bold => 0, italic => 0, underline => 0);
        }
        elsif ($char eq IRC_BOLD) {
            $state{bold} = !$state{bold};
        }
        elsif ($char eq IRC_ITALIC) {
            $state{italic} = !$state{italic};
        }
        elsif ($char eq IRC_UNDERLINE) {
            $state{underline} = !$state{underline};
        }
    }

    return \%state;
}

sub _balanced_line {
    my ($raw, $incoming) = @_;
    my $prefix = '';
    $prefix .= IRC_BOLD      if $incoming->{bold};
    $prefix .= IRC_ITALIC    if $incoming->{italic};
    $prefix .= IRC_UNDERLINE if $incoming->{underline};

    my $outgoing = _style_after($raw, $incoming);
    my $line = $prefix . $raw;
    $line .= IRC_RESET
        if $outgoing->{bold} || $outgoing->{italic} || $outgoing->{underline};

    return ($line, $outgoing);
}

sub _plain_suffix {
    my ($suffix) = @_;
    $suffix = " \x{2026}" unless defined($suffix) && !ref($suffix);
    $suffix =~ s/[\r\n\x00-\x1f\x7f]+/ /g;
    $suffix =~ s/\s{2,}/ /g;
    return $suffix;
}

sub format_ai_reply {
    my ($answer, %options) = @_;
    return [] unless defined($answer) && !ref($answer) && length($answer);

    my $wrap_bytes = $options{wrap_bytes};
    $wrap_bytes = MAX_IRC_BYTES
        unless defined($wrap_bytes) && "$wrap_bytes" =~ /\A\d+\z/;
    $wrap_bytes = 120 if $wrap_bytes < 120;
    $wrap_bytes = MAX_IRC_BYTES if $wrap_bytes > MAX_IRC_BYTES;

    my $max_lines = $options{max_lines};
    $max_lines = MAX_IRC_LINES
        unless defined($max_lines) && "$max_lines" =~ /\A\d+\z/;
    $max_lines = 1 if $max_lines < 1;
    $max_lines = MAX_IRC_LINES if $max_lines > MAX_IRC_LINES;

    my $rendered = _markdown_to_irc($answer);
    return [] unless length $rendered;

    # Reserve four bytes for reopening the three permitted styles and closing
    # them with RESET. This keeps every returned line inside botPrivmsg's real
    # 400-byte payload boundary, including accented text and emoji.
    my @raw = Mediabot::IRC::TextBudget::_split_text_for_irc(
        $rendered,
        $wrap_bytes - 4,
    );
    return [] unless @raw;

    my $truncated = @raw > $max_lines;
    splice @raw, $max_lines if $truncated;

    my %state = (bold => 0, italic => 0, underline => 0);
    my @lines;

    for my $index (0 .. $#raw) {
        my $raw_line = $raw[$index];
        $raw_line =~ s/\s+$//;

        my ($line, $outgoing) = _balanced_line($raw_line, \%state);

        if ($truncated && $index == $#raw) {
            my $suffix = _plain_suffix($options{truncation_suffix});

            while (length($raw_line)
                && _wire_bytes($line . $suffix) > $wrap_bytes) {
                chop $raw_line;
                $raw_line =~ s/\s+$//;
                ($line, $outgoing) = _balanced_line($raw_line, \%state);
            }

            while (length($suffix)
                && _wire_bytes($line . $suffix) > $wrap_bytes) {
                chop $suffix;
            }
            $line .= $suffix;
        }

        push @lines, $line if length $line;
        %state = %$outgoing;
    }

    return \@lines;
}

# Compact renderer API for non-provider callers; defaults and limits are the
# established renderer's contract (at most two lines, each at most 400 bytes).
sub format_reply { return format_ai_reply(@_); }

1;
