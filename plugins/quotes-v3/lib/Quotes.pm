package Mediabot::Plugin::Quotes;

use strict;
use warnings;
use utf8;

use Encode qw(encode);

sub new {
    my ($class, %args) = @_;
    return bless {
        context        => $args{context},
        last_random    => {},
        last_by_author => {},
    }, $class;
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

sub _bold { "\x02$_[0]\x02" }

sub _syntax {
    my ($context, $invocation) = @_;
    $context->notice($invocation, 'Quotes syntax:');
    $context->notice($invocation, 'q [add or a] text1 | text2 | ... | textn');
    $context->notice($invocation, 'q [del or d] id');
    $context->notice($invocation, 'q [view or v] id');
    $context->notice($invocation, 'q [search or s] text');
    $context->notice($invocation, 'q [random or r]');
    return $context->notice($invocation, 'q stats');
}

sub _add {
    my ($self, $context, $invocation, @args) = @_;
    return $context->notice($invocation,
        'q [add or a] text1 | text2 | ... | textn')
        unless @args && defined($args[0]) && length($args[0]);
    my $text = join ' ', @args;
    return $context->notice($invocation,
        'Quote text too long (max 512 chars).') if length($text) > 512;
    my $result = $context->quote_add($invocation, $text);
    return 1 if ($result->{error} // '') eq 'observe';
    return $context->notice($invocation,
        'Channel ' . $invocation->channel . ' is not registered to me')
        if ($result->{error} // '') eq 'channel_unavailable';
    return $context->notice($invocation,
        'Database error while adding quote.') unless $result->{ok};
    return $context->reply($invocation,
        'Quote (id: ' . $result->{id} . ') already exists')
        if ($result->{status} // '') eq 'duplicate';
    my $principal = $invocation->principal;
    my $prefix = $principal->authenticated
        ? '(' . $principal->account . ') ' : '';
    return $context->reply($invocation,
        $prefix . 'done. (id: ' . _bold($result->{id}) . ')');
}

sub _delete {
    my ($self, $context, $invocation, @args) = @_;
    my $id = $args[0];
    return $context->notice($invocation, 'q [del or d] id')
        unless defined($id) && $id =~ /\A[0-9]+\z/ && $id > 0;
    my $result = $context->quote_delete($invocation, $id);
    return 1 if ($result->{error} // '') eq 'observe';
    if (($result->{error} // '') eq 'unauthorized') {
        return $context->notice($invocation,
            'You must be logged to use this command.');
    }
    if (($result->{error} // '') eq 'forbidden') {
        my $level = $result->{required_channel_level} // 100;
        return $context->notice($invocation,
            "You can only delete your own quotes here (or need channel level >= $level, or Administrator).");
    }
    return $context->notice($invocation,
        'Database error while deleting quote.') unless $result->{ok};
    return $context->reply($invocation,
        'Quote (id : ' . $id . ') does not exist for channel '
            . $invocation->channel)
        if ($result->{status} // '') eq 'not_found';
    my $account = $invocation->principal->account || $invocation->nick;
    return $context->reply($invocation,
        "($account) deleted. (id: " . _bold($id) . ')');
}

sub _recall {
    my ($context, $invocation, $id) = @_;
    my $result = $context->quote_recall($invocation, $id);
    return $result && $result->{ok} ? 1 : 0;
}

sub _view {
    my ($self, $context, $invocation, @args) = @_;
    my $id = $args[0];
    return $context->notice($invocation, 'q [view or v] id')
        unless defined($id) && $id =~ /\A[0-9]+\z/ && $id > 0;
    my $result = $context->quote_by_id($invocation, $id);
    return $context->notice($invocation,
        'Database error while reading quote.') unless $result->{ok};
    my $record = $result->{record};
    return $context->reply($invocation,
        "Quote (id : $id) does not exist for channel " . $invocation->channel)
        unless $record;
    $context->reply($invocation,
        '(' . $record->author . ') [id: ' . _bold($record->id) . '] '
            . _excerpt($record->text, 300));
    _recall($context, $invocation, $record->id);
    return 1;
}

sub _search {
    my ($self, $context, $invocation, @args) = @_;
    return $context->notice($invocation,
        'q [search or s] <text> [word2 ...]')
        unless @args && defined($args[0]) && length($args[0]);
    my $display = join ' ', @args;
    my $result = $context->quote_search(
        $invocation, $display, limit => 51);
    return $context->notice($invocation,
        'Database error during search.') unless $result->{ok};
    my @records = @{ $result->{records} || [] };
    return $context->reply($invocation,
        qq{No quote found matching "$display" on } . $invocation->channel)
        unless @records;
    return $context->reply($invocation,
        qq{More than 50 quotes matching "$display" on }
            . $invocation->channel . ' — please be more specific :)')
        if @records > 50;
    my @words = grep { length } split /\s+/, lc($display);
    my @scored = map {
        my $record = $_;
        my $text = lc($record->text);
        my $score = 0;
        $score += () = $text =~ /\Q$_\E/g for @words;
        [$record, $score]
    } @records;
    @scored = sort {
        $b->[1] <=> $a->[1] || $b->[0]->id <=> $a->[0]->id
    } @scored;
    my $count = @records;
    my $last = $count > 10 ? 9 : $count - 1;
    my $ids = join '|', map { $_->[0]->id } @scored[0 .. $last];
    $ids .= ' ...' if $count > 10;
    $context->reply($invocation,
        qq{$count quote(s) matching "$display" on }
            . $invocation->channel . " : $ids");
    my $best = $scored[0][0];
    return $context->reply($invocation,
        'Best match on ' . $best->created_at . ' by ' . $best->author
            . ' (id : ' . _bold($best->id) . ') '
            . _excerpt($best->text, 200));
}

sub _random {
    my ($self, $context, $invocation) = @_;
    my $channel = $invocation->channel;
    my $count = $context->quote_count($invocation);
    return $context->notice($invocation,
        'Database error while reading quotes.') unless $count->{ok};
    return $context->reply($invocation,
        "Quote database is empty for $channel") unless $count->{count};
    my %args;
    $args{exclude_id} = $self->{last_random}{$channel}
        if $count->{count} > 1 && defined($self->{last_random}{$channel});
    my $result = $context->quote_random($invocation, %args);
    return $context->notice($invocation,
        'Database error while reading quote.') unless $result->{ok};
    my $record = $result->{record};
    return $context->reply($invocation,
        "Quote database is empty for $channel") unless $record;
    $self->{last_random}{$channel} = $record->id;
    $context->reply($invocation,
        '(' . $record->author . ') [id: ' . _bold($record->id) . '] '
            . _excerpt($record->text, 300));
    _recall($context, $invocation, $record->id);
    return 1;
}

sub _age {
    my ($epoch) = @_;
    my $age = defined($epoch) && $epoch =~ /\A[0-9]+\z/
        ? time() - $epoch : 0;
    $age = 0 if $age < 0;
    my @units = (
        ['year', 31536000], ['month', 2592000], ['day', 86400],
        ['hour', 3600], ['minute', 60], ['second', 1],
    );
    for my $unit (@units) {
        next if $age < $unit->[1];
        my $n = int($age / $unit->[1]);
        return "$n $unit->[0]" . ($n > 1 ? 's' : '');
    }
    return '0 second';
}

sub _stats {
    my ($self, $context, $invocation) = @_;
    my $result = $context->quote_stats($invocation);
    return $context->notice($invocation,
        'Database error while reading quote stats.') unless $result->{ok};
    my $channel = $invocation->channel;
    return $context->reply($invocation,
        "Quote database is empty for $channel") unless $result->{count};
    my $top = $result->{top_count}
        ? ' — top: ' . ($result->{top_author} // 'Anonymous')
            . ' (' . $result->{top_count} . ')' : '';
    return $context->reply($invocation,
        "Quotes on $channel: $result->{count} total — oldest "
            . _age($result->{oldest_epoch}) . ' ago, latest '
            . _age($result->{newest_epoch}) . " ago$top");
}

sub _by_author {
    my ($self, $context, $invocation, $target) = @_;
    return $context->notice($invocation, 'Syntax: quote <nick>')
        unless defined($target) && length($target);
    my $key = $invocation->channel . ':' . lc($target);
    my %common = (author_match => 'prefix');
    $common{exclude_id} = $self->{last_by_author}{$key}
        if defined $self->{last_by_author}{$key};
    my $result = $context->quote_random_by_author(
        $invocation, $target, %common);
    if ($result->{ok} && !$result->{record} && exists($common{exclude_id})) {
        delete $common{exclude_id};
        $result = $context->quote_random_by_author(
            $invocation, $target, %common);
    }
    if ($result->{ok} && !$result->{record}) {
        $result = $context->quote_random_by_author(
            $invocation, $target, author_match => 'contains');
    }
    return $context->notice($invocation,
        'Database error while reading quote.') unless $result->{ok};
    my $record = $result->{record};
    return $context->notice($invocation,
        "No quotes from $target on " . $invocation->channel . '.')
        unless $record;
    $self->{last_by_author}{$key} = $record->id;
    return $context->reply($invocation,
        '[' . $record->id . '] <' . $record->author . '> '
            . _excerpt($record->text, 300));
}

sub command_q {
    my ($self, $context, $invocation) = @_;
    my @args = @{ $invocation->args };
    return _syntax($context, $invocation) unless @args && length($args[0]);
    my $subcommand = lc shift @args;
    return $self->_add($context, $invocation, @args)
        if $subcommand =~ /\A(?:add|a)\z/;
    return $self->_delete($context, $invocation, @args)
        if $subcommand =~ /\A(?:del|d)\z/;
    return $self->_view($context, $invocation, @args)
        if $subcommand =~ /\A(?:view|v)\z/;
    return $self->_search($context, $invocation, @args)
        if $subcommand =~ /\A(?:search|s)\z/;
    return $self->_random($context, $invocation)
        if $subcommand =~ /\A(?:random|r)\z/;
    return $self->_stats($context, $invocation)
        if $subcommand eq 'stats';
    return _syntax($context, $invocation)
        if $invocation->principal->authenticated;
    return $context->notice($invocation,
        'You must be logged to use this command.');
}

sub command_quote {
    my ($self, $context, $invocation) = @_;
    my @args = @{ $invocation->args };
    if (@args && lc($args[0]) eq 'add') {
        shift @args;
        return $self->_add($context, $invocation, @args);
    }
    if (@args && lc($args[0]) eq 'count') {
        shift @args;
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
    return $self->_by_author($context, $invocation, $args[0]);
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
