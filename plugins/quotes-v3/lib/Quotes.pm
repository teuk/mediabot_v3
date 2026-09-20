package Mediabot::Plugin::Quotes;

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
        last if $used + $size > $max;
        $out .= $character;
        $used += $size;
    }
    return $out . '...';
}

sub command_quotecount {
    my ($self, $context, $invocation) = @_;
    my @args = @{ $invocation->args };
    my $target = $args[0];
    my $result = defined($target) && length($target)
        ? $context->quote_count($invocation,
            author => $target, author_match => 'prefix')
        : $context->quote_count($invocation);
    return $context->notice($invocation, 'Database error.')
        unless $result && $result->{ok};

    my $count = $result->{count} // 0;
    return $context->reply($invocation,
        defined($target) && length($target)
            ? "$target: $count quote(s) on " . $invocation->channel
            : $invocation->channel . ": $count quote(s) total");
}

sub command_topquote {
    my ($self, $context, $invocation) = @_;
    my $channel = $invocation->channel;
    return $context->notice($invocation,
        'Syntax: !topquote [n]  (use it in a channel)')
        unless defined($channel) && $channel =~ /\A[#&]/;

    my @args = @{ $invocation->args };
    my $limit = 5;
    if (defined($args[0]) && $args[0] =~ /\A(\d{1,2})\z/) {
        $limit = 0 + $1;
        $limit = 1 if $limit < 1;
        $limit = 10 if $limit > 10;
    }
    my $result = $context->top_quotes($invocation, limit => $limit);
    return $context->notice($invocation,
        'topquote: database unavailable.')
        unless $result && $result->{ok};
    my $records = $result->{records} || [];
    return $context->reply($invocation,
        "No quotes yet on $channel — add some with !q add <text>.")
        unless @$records;

    $context->reply($invocation,
        "\x02Hall of fame\x02 $channel — most recalled quotes:");
    my $rank = 0;
    for my $record (@$records) {
        $rank++;
        my $hits = $record->hits;
        my $prefix = sprintf('%d. [id:%d] <%s> ',
            $rank, $record->id, $record->author);
        my $suffix = sprintf(' (%d recall%s)',
            $hits, $hits == 1 ? '' : 's');
        my $budget = 400 - _wire_length($prefix) - _wire_length($suffix) - 3;
        $budget = 1 if $budget < 1;
        $budget = 200 if $budget > 200;
        $context->reply($invocation,
            $prefix . _excerpt($record->text, $budget) . $suffix);
    }
    return 1;
}

1;
