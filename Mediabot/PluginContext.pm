package Mediabot::PluginContext;

use strict;
use warnings;
use utf8;

use Encode qw(encode);
use Scalar::Util qw(refaddr);

my %STATE;

sub _state {
    my ($self) = @_;
    return $STATE{ refaddr($self) };
}

sub new {
    my ($class, %args) = @_;

    die "PluginContext: plugin name is required\n"
        unless defined($args{plugin}) && !ref($args{plugin})
            && $args{plugin} =~ /\A[a-z0-9][a-z0-9-]{0,47}\z/;

    my $requested = ref($args{requested}) eq 'ARRAY' ? $args{requested} : [];
    my $granted   = ref($args{granted}) eq 'ARRAY'   ? $args{granted}   : [];
    my %requested = map { $_ => 1 } grep { defined($_) && !ref($_) } @$requested;
    my %granted   = map { $_ => 1 } grep { defined($_) && !ref($_) } @$granted;
    my %effective = map { $_ => 1 } grep { $granted{$_} } keys %requested;

    my $opaque = 0;
    my $self = bless \$opaque, $class;
    $STATE{ refaddr($self) } = {
        plugin    => $args{plugin},
        requested => \%requested,
        granted   => \%granted,
        effective => \%effective,
        http_fetch_sink => $args{http_fetch_sink},
        storage_snapshot_sink => $args{storage_snapshot_sink},
        storage_commit_sink => $args{storage_commit_sink},
        quotes_read_sink => $args{quotes_read_sink},
        quotes_write_sink => $args{quotes_write_sink},
        factoids_read_sink => $args{factoids_read_sink},
        factoids_write_sink => $args{factoids_write_sink},
        channel_activity_read_sink => $args{channel_activity_read_sink},
    };
    return $self;
}

sub plugin { _state($_[0])->{plugin} }

sub requested_capabilities {
    my ($self) = @_;
    return sort keys %{ _state($self)->{requested} };
}

sub granted_capabilities {
    my ($self) = @_;
    return sort keys %{ _state($self)->{granted} };
}

sub effective_capabilities {
    my ($self) = @_;
    return sort keys %{ _state($self)->{effective} };
}

sub has_capability {
    my ($self, $capability) = @_;
    return 0 unless defined($capability) && !ref($capability);
    return _state($self)->{effective}{$capability} ? 1 : 0;
}

sub require_capability {
    my ($self, $capability) = @_;
    my $state = _state($self);
    die "PluginContext: capability '$capability' was not granted to '$state->{plugin}'\n"
        unless $self->has_capability($capability);
    return 1;
}

sub _text {
    my ($value) = @_;
    die "PluginContext: output must be a scalar\n"
        unless defined($value) && !ref($value);
    my $text = "$value";
    $text =~ s/[\r\n\0]+/ /g;
    $text =~ s/^\s+|\s+$//g;
    die "PluginContext: output must not be empty\n" unless length $text;
    die "PluginContext: output exceeds 400 bytes\n"
        if length(encode('UTF-8', $text)) > 400;
    return $text;
}

sub reply {
    my ($self, $invocation, $text) = @_;
    $self->require_capability('irc.reply');
    die "PluginContext: invalid invocation\n"
        unless ref($invocation) && eval { $invocation->can('_emit_reply') };
    return $invocation->_emit_reply(_text($text));
}

sub notice {
    my ($self, $invocation, $text) = @_;
    $self->require_capability('irc.notice');
    die "PluginContext: invalid invocation\n"
        unless ref($invocation) && eval { $invocation->can('_emit_notice') };
    return $invocation->_emit_notice(_text($text));
}

sub channel_message {
    my ($self, $invocation, $text) = @_;
    $self->require_capability('irc.channel_message');
    die "PluginContext: invalid channel invocation\n"
        unless ref($invocation)
            && eval { $invocation->can('_emit_channel_message') };
    return $invocation->_emit_channel_message(_text($text));
}

sub _invocation {
    my ($invocation) = @_;
    die "PluginContext: invalid scoped invocation\n"
        unless ref($invocation)
            && eval { $invocation->can('channel') }
            && eval { $invocation->can('activation_mode') };
    return $invocation;
}

sub http_fetch {
    my ($self, $invocation, $request, $callback) = @_;
    $self->require_capability('http.fetch');
    _invocation($invocation);
    die "PluginContext: HTTP request must be an object\n"
        unless ref($request) eq 'HASH';
    die "PluginContext: HTTP callback must be CODE\n"
        unless ref($callback) eq 'CODE';
    my $sink = _state($self)->{http_fetch_sink};
    die "PluginContext: HTTP service is unavailable\n"
        unless ref($sink) eq 'CODE';
    return $sink->($invocation, $request, $callback);
}

sub storage_snapshot {
    my ($self, $invocation) = @_;
    $self->require_capability('storage.kv');
    _invocation($invocation);
    my $sink = _state($self)->{storage_snapshot_sink};
    die "PluginContext: storage service is unavailable\n"
        unless ref($sink) eq 'CODE';
    return $sink->($invocation);
}

sub storage_commit {
    my ($self, $invocation, %args) = @_;
    $self->require_capability('storage.kv');
    _invocation($invocation);
    my $sink = _state($self)->{storage_commit_sink};
    die "PluginContext: storage service is unavailable\n"
        unless ref($sink) eq 'CODE';
    return $sink->($invocation, %args);
}

sub _quotes_read {
    my ($self, $invocation, $operation, $args) = @_;
    $self->require_capability('data.quotes.read');
    _invocation($invocation);
    die "PluginContext: quote arguments must be an object\n"
        unless ref($args) eq 'HASH';
    my $sink = _state($self)->{quotes_read_sink};
    die "PluginContext: quote data service is unavailable\n"
        unless ref($sink) eq 'CODE';
    return $sink->($invocation, $operation, { %$args });
}

sub quote_by_id {
    my ($self, $invocation, $id) = @_;
    return $self->_quotes_read($invocation, 'by_id', { id => $id });
}

sub quote_random {
    my ($self, $invocation, %args) = @_;
    return $self->_quotes_read($invocation, 'random',
        { exclude_id => $args{exclude_id} });
}

sub quote_search {
    my ($self, $invocation, $query, %args) = @_;
    return $self->_quotes_read($invocation, 'search',
        { query => $query, limit => $args{limit} });
}

sub quotes_by_author {
    my ($self, $invocation, $author, %args) = @_;
    return $self->_quotes_read($invocation, 'by_author',
        { author => $author, limit => $args{limit},
          author_match => $args{author_match} });
}

sub quote_random_by_author {
    my ($self, $invocation, $author, %args) = @_;
    return $self->_quotes_read($invocation, 'random_by_author',
        { author => $author, author_match => $args{author_match},
          exclude_id => $args{exclude_id} });
}

sub quote_stats {
    my ($self, $invocation) = @_;
    return $self->_quotes_read($invocation, 'stats', {});
}

sub quote_count {
    my ($self, $invocation, %args) = @_;
    return $self->_quotes_read($invocation, 'count',
        { author => $args{author}, author_match => $args{author_match} });
}

sub top_quotes {
    my ($self, $invocation, %args) = @_;
    return $self->_quotes_read($invocation, 'top',
        { limit => $args{limit} });
}

sub _factoids_read {
    my ($self, $invocation, $operation, $args) = @_;
    $self->require_capability('data.factoids.read');
    _invocation($invocation);
    die "PluginContext: factoid arguments must be an object\n"
        unless ref($args) eq 'HASH';
    my $sink = _state($self)->{factoids_read_sink};
    die "PluginContext: factoid data service is unavailable\n"
        unless ref($sink) eq 'CODE';
    return $sink->($invocation, $operation, { %$args });
}

sub factoid_by_keyword {
    my ($self, $invocation, $keyword) = @_;
    return $self->_factoids_read(
        $invocation, 'by_keyword', { keyword => $keyword });
}

sub factoid_list {
    my ($self, $invocation, %args) = @_;
    return $self->_factoids_read($invocation, 'list', {
        pattern => $args{pattern}, limit => $args{limit},
    });
}

sub top_factoids {
    my ($self, $invocation, %args) = @_;
    return $self->_factoids_read(
        $invocation, 'top', { limit => $args{limit} });
}

sub _channel_activity_read {
    my ($self, $invocation, $operation, $args) = @_;
    $self->require_capability('data.channel_activity.read');
    _invocation($invocation);
    die "PluginContext: channel activity arguments must be an object\n"
        unless ref($args) eq 'HASH';
    my $sink = _state($self)->{channel_activity_read_sink};
    die "PluginContext: channel activity data service is unavailable\n"
        unless ref($sink) eq 'CODE';
    return $sink->($invocation, $operation, { %$args });
}

sub activity_compare {
    my ($self, $invocation, $left, $right, %args) = @_;
    return $self->_channel_activity_read($invocation, 'compare', {
        left => $left, right => $right, period => $args{period},
    });
}

sub activity_heatmap {
    my ($self, $invocation, $nick) = @_;
    return $self->_channel_activity_read(
        $invocation, 'heatmap', { nick => $nick });
}

sub _factoids_write {
    my ($self, $invocation, $operation, $args) = @_;
    $self->require_capability('data.factoids.write');
    _invocation($invocation);
    die "PluginContext: factoid write arguments must be an object\n"
        unless ref($args) eq 'HASH';
    my $sink = _state($self)->{factoids_write_sink};
    die "PluginContext: factoid write service is unavailable\n"
        unless ref($sink) eq 'CODE';
    return $sink->($invocation, $operation, { %$args });
}

sub factoid_upsert {
    my ($self, $invocation, $keyword, $value) = @_;
    return $self->_factoids_write($invocation, 'upsert', {
        keyword => $keyword, value => $value,
    });
}

sub factoid_delete {
    my ($self, $invocation, $keyword) = @_;
    return $self->_factoids_write(
        $invocation, 'delete', { keyword => $keyword });
}

sub factoid_recall {
    my ($self, $invocation, $keyword) = @_;
    return $self->_factoids_write(
        $invocation, 'recall', { keyword => $keyword });
}

sub _quotes_write {
    my ($self, $invocation, $operation, $args) = @_;
    $self->require_capability('data.quotes.write');
    _invocation($invocation);
    die "PluginContext: quote write arguments must be an object\n"
        unless ref($args) eq 'HASH';
    my $sink = _state($self)->{quotes_write_sink};
    die "PluginContext: quote write service is unavailable\n"
        unless ref($sink) eq 'CODE';
    return $sink->($invocation, $operation, { %$args });
}

sub quote_add {
    my ($self, $invocation, $text) = @_;
    return $self->_quotes_write($invocation, 'add', { text => $text });
}

sub quote_delete {
    my ($self, $invocation, $id) = @_;
    return $self->_quotes_write($invocation, 'delete', { id => $id });
}

sub quote_recall {
    my ($self, $invocation, $id) = @_;
    return $self->_quotes_write($invocation, 'recall', { id => $id });
}

sub DESTROY {
    my ($self) = @_;
    delete $STATE{ refaddr($self) };
}

1;
