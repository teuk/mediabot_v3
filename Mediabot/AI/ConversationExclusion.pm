package Mediabot::AI::ConversationExclusion;

use strict;
use warnings;

use Carp qw(croak);

our $VERSION = '1.0';

my $MAX_CONFIG_CHARS = 8_192;
my $MAX_CHANNELS = 64;
my $MAX_ITEMS_PER_CHANNEL = 64;

sub _plain_scalar {
    my ($value) = @_;
    return defined($value) && !ref($value);
}

sub _raw_values {
    my ($value) = @_;
    return () unless defined $value;
    return grep { _plain_scalar($_) } @$value if ref($value) eq 'ARRAY';
    return _plain_scalar($value) ? ("$value") : ();
}

sub _irc_fold {
    my ($value) = @_;
    return undef unless _plain_scalar($value);
    my $folded = lc "$value";
    $folded =~ tr/[]\\^/{}|~/;
    return $folded;
}

sub _nick_key {
    my ($nick) = @_;
    return undef unless _plain_scalar($nick);
    $nick = "$nick";
    $nick =~ s/^\s+|\s+$//g;
    return undef unless length($nick) >= 1
        && length($nick) <= 100
        && $nick !~ /[\s,;:=+\x00-\x1f\x7f]/;
    return _irc_fold($nick);
}

sub _channel_key {
    my ($channel) = @_;
    return undef unless _plain_scalar($channel);
    $channel = "$channel";
    $channel =~ s/^\s+|\s+$//g;
    $channel =~ s/^#//;
    return undef unless length($channel) >= 1
        && length($channel) <= 79
        && $channel !~ /[\s,;:=+\x00-\x1f\x7f]/;
    return '#' . _irc_fold($channel);
}

sub _command_key {
    my ($command) = @_;
    return undef unless _plain_scalar($command);
    $command = lc "$command";
    $command =~ s/^\s+|\s+$//g;
    return undef unless $command =~ /\A[!.?\/][a-z0-9][a-z0-9_.-]{0,63}\z/;
    return $command;
}

sub _config_signature {
    my (@values) = @_;
    return join "\x1e", map {
        ref($_) eq 'ARRAY'
            ? ('ARRAY:' . join("\x1f", map { defined($_) && !ref($_) ? "$_" : '' } @$_))
            : defined($_) && !ref($_) ? "SCALAR:$_" : 'UNSET'
    } @values;
}

sub _compile_channel_map {
    my ($raw, $normalizer) = @_;
    my %map;
    my $text = join '|', _raw_values($raw);
    $text = substr($text, 0, $MAX_CONFIG_CHARS)
        if length($text) > $MAX_CONFIG_CHARS;

    for my $clause (split /\|/, $text) {
        last if scalar(keys %map) >= $MAX_CHANNELS;
        next unless defined($clause) && $clause =~ /\A\s*([^:]+?)\s*:\s*(.+?)\s*\z/;
        my ($channel_raw, $items_raw) = ($1, $2);
        my $channel = _channel_key($channel_raw);
        next unless defined $channel;
        my $bucket = ($map{$channel} ||= {});
        for my $token (split /[+\s]+/, $items_raw) {
            my $item = $normalizer->($token);
            $bucket->{$item} = 1 if defined($item);
            last if scalar(keys %$bucket) >= $MAX_ITEMS_PER_CHANNEL;
        }
        delete $map{$channel} unless keys %$bucket;
    }
    return \%map;
}

sub new {
    my ($class, %args) = @_;
    my $conf = $args{conf};
    croak 'configuration object with get() is required'
        unless $conf && eval { $conf->can('get') };
    return bless {
        conf      => $conf,
        signature => undef,
        channel_bots => {},
        channel_commands => {},
    }, $class;
}

sub _refresh {
    my ($self) = @_;
    my $conf = $self->{conf};
    my $bots = $conf->get('conversation.CHANNEL_BOTS');
    my $commands = $conf->get('conversation.CHANNEL_COMMANDS');
    my $signature = _config_signature($bots, $commands);
    return if defined($self->{signature}) && $self->{signature} eq $signature;

    $self->{channel_bots} = _compile_channel_map($bots, \&_nick_key);
    $self->{channel_commands} = _compile_channel_map($commands, \&_command_key);
    $self->{signature} = $signature;
    return 1;
}

sub _decision {
    my (%args) = @_;
    return {
        excluded => $args{excluded} ? 1 : 0,
        reason   => $args{reason},
    };
}

sub classify_public_line {
    my ($self, %args) = @_;
    croak 'conversation exclusion object is required' unless ref($self);
    $self->_refresh();

    my $channel = _channel_key($args{channel});
    return _decision(excluded => 0, reason => 'invalid_channel')
        unless defined $channel;
    my $nick = _nick_key($args{nick});
    return _decision(excluded => 0, reason => 'invalid_nick')
        unless defined $nick;
    my $message = _plain_scalar($args{message}) ? "$args{message}" : '';
    $message =~ s/^\s+|\s+$//g;

    my $channel_bots = $self->{channel_bots}{$channel} || {};
    my %senders = %$channel_bots;
    my $self_nick = _nick_key($args{bot_nick});
    $senders{$self_nick} = 1 if defined $self_nick;
    return _decision(excluded => 1, reason => 'declared_bot')
        if $senders{$nick};

    my %interaction_bots = %$channel_bots;
    if ($message =~ /\A\s*\@?([^\s,:]{1,100})(?:\s*[:,]\s*|\s+|\s*\z)/) {
        my $addressed = _nick_key($1);
        return _decision(excluded => 1, reason => 'bot_address')
            if defined($addressed) && $interaction_bots{$addressed};
    }

    if ($message !~ /\A\x01/) {
        my ($word) = split /\s+/, $message;
        my $command = _command_key($word);
        my $commands = $self->{channel_commands}{$channel} || {};
        return _decision(excluded => 1, reason => 'bot_command')
            if defined($command) && $commands->{$command};
    }

    return _decision(excluded => 0, reason => 'human');
}

1;
