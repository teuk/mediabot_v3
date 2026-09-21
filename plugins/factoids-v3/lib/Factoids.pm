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

1;
