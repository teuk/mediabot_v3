package Mediabot::Plugin::Factoids;

use strict;
use warnings;
use utf8;

use Encode qw(encode);

sub new {
    my ($class, %args) = @_;
    return bless { context => $args{context} }, $class;
}

sub start { $_[0]{started} = 1; 1 }
sub stop  { $_[0]{started} = 0; 1 }

sub _wire_length { length(encode('UTF-8', $_[0] // '')) }

sub _excerpt {
    my ($text, $max) = @_;
    $text = '' unless defined $text;
    return $text if _wire_length($text) <= $max;
    my ($out, $used) = ('', 0);
    for my $character (split //, $text) {
        my $size = _wire_length($character);
        last if $used + $size > $max - 3;
        $out .= $character;
        $used += $size;
    }
    return $out . '...';
}

sub _channel_ok {
    my ($invocation) = @_;
    my $channel = $invocation->channel;
    return defined($channel) && !ref($channel)
        && $channel =~ /\A[#&+!][^\x00\x07\r\n ,:]+\z/ ? 1 : 0;
}

sub _keyword {
    my ($invocation) = @_;
    my $keyword = lc join ' ', @{ $invocation->args };
    $keyword =~ s/^\s+|\s+$//g;
    return $keyword;
}

sub _truncate_wire {
    my ($text, $max) = @_;
    $text = '' unless defined $text;
    return $text if _wire_length($text) <= $max && length($text) <= $max;
    my ($out, $used, $characters) = ('', 0, 0);
    for my $character (split //, $text) {
        my $size = _wire_length($character);
        last if $used + $size > $max || $characters >= $max;
        $out .= $character;
        $used += $size;
        $characters++;
    }
    return $out;
}

sub _date {
    my ($value) = @_;
    return '?' unless defined($value) && !ref($value) && length($value);
    return $1 if $value =~ /\A(\d{4}-\d{2}-\d{2})/;
    return _excerpt($value, 64);
}

sub _notice_items {
    my ($context, $invocation, $prefix, $items) = @_;
    my $line = $prefix;
    my $continuation = 'Factoids continued: ';
    for my $item (@$items) {
        my $separator = $line eq $prefix ? '' : ', ';
        if (_wire_length($line . $separator . $item) > 400) {
            $context->notice($invocation, $line);
            $line = $continuation . $item;
        }
        else {
            $line .= $separator . $item;
        }
    }
    return $context->notice($invocation, _excerpt($line, 400));
}

sub command_factoid {
    my ($self, $context, $invocation) = @_;
    return $context->notice($invocation,
        'Syntax: factoid <keyword>  (use it in a channel)')
        unless _channel_ok($invocation);

    my $keyword = _keyword($invocation);
    return $context->notice($invocation, 'Syntax: factoid <keyword>')
        unless $keyword =~ /\A[a-z0-9_.-]{1,64}\z/;

    my $result = $context->factoid_by_keyword($invocation, $keyword);
    return $context->notice($invocation, 'factoid: database unavailable.')
        unless $result && $result->{ok};
    my $record = $result->{record};
    return $context->notice($invocation, "I don't know '$keyword'.")
        unless $record;

    my $author = $record->author;
    $author = 'unknown' if !defined($author) || !length($author)
        || lc($author) eq 'unknown';
    my $created = _date($record->created_at);
    my $updated = _date($record->updated_at);
    my $hits = $record->hits;
    my $date_part = $updated ne $created
        ? "created $created by $author, updated $updated"
        : "created $created by $author";
    my $head = "factoid '$keyword': $date_part, $hits recall(s).";
    $context->notice($invocation, _excerpt($head, 400));
    return $context->notice($invocation,
        'value: ' . _excerpt($record->value, 393));
}

sub command_factoids {
    my ($self, $context, $invocation) = @_;
    return $context->notice($invocation,
        'Syntax: factoids [pattern]  (use it in a channel)')
        unless _channel_ok($invocation);

    my $channel = $invocation->channel;
    my $pattern = _keyword($invocation);
    if ($pattern eq 'top') {
        my $result = $context->top_factoids($invocation, limit => 10);
        return $context->notice($invocation, 'factoids: listing failed.')
            unless $result && $result->{ok};
        my $items = $result->{items} || [];
        return $context->notice($invocation,
            "No factoids have been recalled yet on $channel.") unless @$items;
        my @rendered = map {
            ($_->{keyword} // '') . ' (' . ($_->{hits} // 0) . ')'
        } @$items;
        return _notice_items($context, $invocation,
            "Top factoids on $channel: ", \@rendered);
    }

    my %args;
    $args{pattern} = $pattern
        if $pattern =~ /\A[a-z0-9_.?*-]{1,64}\z/;
    my $result = $context->factoid_list($invocation, %args, limit => 60);
    return $context->notice($invocation, 'factoids: listing failed.')
        unless $result && $result->{ok};
    my $keywords = $result->{keywords} || [];
    unless (@$keywords) {
        return $context->notice($invocation, length($pattern)
            ? "No factoids matching '$pattern' on $channel."
            : "No factoids on $channel yet. Add one: learn <keyword> = <value>");
    }
    return _notice_items($context, $invocation,
        scalar(@$keywords) . " factoid(s) on $channel: ", $keywords);
}

sub command_whatis {
    my ($self, $context, $invocation) = @_;
    my @args = @{ $invocation->args };
    my $quiet = @args && $args[0] eq '__quiet__' ? 1 : 0;
    shift @args if $quiet;

    unless (_channel_ok($invocation)) {
        return 1 if $quiet;
        return $context->notice($invocation,
            'Syntax: whatis <keyword>  (use it in a channel)');
    }

    my $keyword = lc join ' ', @args;
    $keyword =~ s/^\s+|\s+$//g;
    unless ($keyword =~ /\A[a-z0-9_.-]{1,64}\z/) {
        return 1 if $quiet;
        return $context->notice($invocation, 'Syntax: whatis <keyword>');
    }

    my $result = $context->factoid_by_keyword($invocation, $keyword);
    unless ($result && $result->{ok}) {
        return 1 if $quiet;
        return $context->notice($invocation,
            'whatis: database unavailable.');
    }
    my $record = $result->{record};
    unless ($record) {
        return 1 if $quiet;
        return $context->notice($invocation,
            "I don't know '$keyword'. Teach me: learn $keyword = ...");
    }

    # Historical recall accounting is best-effort and never withholds the
    # visible value. The core policy suppresses this mutation in observe, so
    # the saved handler remains the only counter writer until explicit on.
    $context->factoid_recall($invocation, $keyword);
    my $prefix = $keyword . ': ';
    my $budget = 400 - _wire_length($prefix);
    return $context->reply($invocation,
        $prefix . _excerpt($record->value, $budget));
}

sub command_learn {
    my ($self, $context, $invocation) = @_;
    return $context->notice($invocation,
        'Syntax: learn <keyword> = <value>  (use it in a channel)')
        unless _channel_ok($invocation);

    my $raw = join ' ', @{ $invocation->args };
    $raw =~ s/^\s+|\s+$//g;
    return $context->notice($invocation,
        'Syntax: learn <keyword> = <value>')
        unless $raw =~ /^(.+?)\s*=\s*(.+)$/;

    my ($keyword, $value) = (lc($1), $2);
    $keyword =~ s/^\s+|\s+$//g;
    $value =~ s/[\r\n\0]+/ /g;
    $value =~ s/^\s+|\s+$//g;
    return $context->notice($invocation,
        'learn: keyword must be 1-64 chars of letters/digits/_.- (no spaces).')
        unless $keyword =~ /\A[a-z0-9_.-]{1,64}\z/;
    return $context->notice($invocation, 'learn: value cannot be empty.')
        unless length $value;
    $value = _truncate_wire($value, 400);

    my $result = $context->factoid_upsert(
        $invocation, $keyword, $value);
    return 1 if ($result->{error} // '') eq 'observe';
    return $context->notice($invocation,
        'learn: channel not known to the bot.')
        if ($result->{error} // '') eq 'channel_unavailable';
    return $context->notice($invocation,
        'learn: could not store the factoid.') unless $result->{ok};
    return $context->notice($invocation,
        "Learned '$keyword' for " . $invocation->channel . '.');
}

sub command_forget {
    my ($self, $context, $invocation) = @_;
    return $context->notice($invocation,
        'Syntax: forget <keyword>  (use it in a channel)')
        unless _channel_ok($invocation);

    my $keyword = _keyword($invocation);
    return $context->notice($invocation, 'Syntax: forget <keyword>')
        unless $keyword =~ /\A[a-z0-9_.-]{1,64}\z/;

    my $result = $context->factoid_delete($invocation, $keyword);
    return 1 if ($result->{error} // '') eq 'observe';
    if (($result->{error} // '') =~ /\A(?:unauthorized|forbidden)\z/) {
        return $context->notice($invocation,
            "forget: only the author or a channel op can forget '$keyword'.");
    }
    return $context->notice($invocation, "I don't know '$keyword'.")
        if $result->{ok} && ($result->{status} // '') eq 'not_found';
    return $context->notice($invocation, 'forget: delete failed.')
        unless $result->{ok};
    return $context->notice($invocation,
        "Forgot '$keyword' on " . $invocation->channel . '.');
}

1;
