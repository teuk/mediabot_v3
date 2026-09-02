package Mediabot::Hailo::Normalizer;

use strict;
use warnings;
use utf8;

use Digest::SHA qw(sha256_hex);
use Exporter 'import';

our $VERSION = '1.0';
our @EXPORT_OK = qw(
    normalize_hailo_input
    rehydrate_hailo_output
    hailo_placeholder_for_nick
);

my $SELF_TOKEN    = 'zzhailoselfzz';
my $SPEAKER_TOKEN = 'zzhailospeakerzz';
my $NICK_PREFIX   = 'zzhailonick';
my $NICK_SUFFIX   = 'zz';
my $BUCKETS       = 32;

sub _plain {
    my ($value) = @_;
    return defined($value) && !ref($value);
}

sub _irc_fold {
    my ($value) = @_;
    return '' unless _plain($value);
    my $folded = lc "$value";
    $folded =~ tr/[]\\^/{}|~/;
    return $folded;
}

sub _clean_line {
    my ($value, $max) = @_;
    return undef unless _plain($value);

    my $text = "$value";
    return undef if $text =~ /\x00/;
    $text =~ s/[\r\n\t]+/ /g;
    $text =~ s/\x03\d{0,2}(?:,\d{1,2})?//g;
    $text =~ s/[\x02\x0f\x16\x1d\x1f]//g;
    $text =~ s/[\x01-\x08\x0b\x0c\x0e\x11-\x15\x17-\x1c\x1e\x7f]//g;
    $text =~ s/^\s+|\s+$//g;
    $text =~ s/\s{2,}/ /g;
    return undef unless length($text);
    return undef if defined($max) && length($text) > $max;
    return $text;
}

sub _channel_key {
    my ($channel) = @_;
    return undef unless _plain($channel)
        && "$channel" =~ /^[#&+!][^\s,\x00-\x1f\x7f]{1,79}\z/;
    return _irc_fold($channel);
}

sub _nick_list {
    my ($values) = @_;
    return () unless ref($values) eq 'ARRAY';

    my %seen;
    return sort { length($b) <=> length($a) || lc($a) cmp lc($b) }
        grep {
            _plain($_) && length($_) && length($_) <= 64
                && !$seen{ _irc_fold($_) }++
        } @$values;
}

sub _nick_pattern {
    my ($nick) = @_;
    return qr/(?<![\p{L}\p{N}_])\Q$nick\E(?![\p{L}\p{N}_])/iu;
}

sub hailo_placeholder_for_nick {
    my (%args) = @_;
    my $channel = _channel_key($args{channel});
    return undef unless defined($channel) && _plain($args{nick}) && length("$args{nick}");

    my $digest = sha256_hex(join "\x00", $channel, _irc_fold($args{nick}));
    my $bucket = hex(substr($digest, 0, 8)) % $BUCKETS;
    return sprintf('%s%02d%s', $NICK_PREFIX, $bucket, $NICK_SUFFIX);
}

sub _strip_paste_prefixes {
    my ($text, $nicks) = @_;

    # Timestamp and common copied-log prefixes. Only the beginning of a line is
    # touched; ordinary parentheses and angle brackets later in the sentence
    # remain part of the training material.
    for (1 .. 3) {
        my $before = $text;
        $text =~ s/^\s*[\[(]\d{1,2}:\d{2}(?::\d{2})?(?:[.]\d+)?[\])]\s*//u;
        $text =~ s/^\s*[<(][^<>()\r\n]{1,64}[>)]\s*//u;

        for my $nick (@$nicks) {
            my $quoted = quotemeta($nick);
            if ($text =~ s/^\s*\@?$quoted\s*(?:>+|[|:,~])\s*//iu) {
                last;
            }
        }
        last if $text eq $before;
    }
    return $text;
}

sub _is_command {
    my ($text, $prefixes) = @_;
    return 0 unless _plain($text) && length($text);
    return 0 unless ref($prefixes) eq 'ARRAY';

    for my $prefix (@$prefixes) {
        next unless _plain($prefix) && length($prefix) == 1;
        return 1 if index($text, "$prefix") == 0;
    }
    return 0;
}

sub normalize_hailo_input {
    my (%args) = @_;
    my $channel = _channel_key($args{channel});
    return { ok => 0, reason => 'invalid_channel' } unless defined $channel;

    my $max = _plain($args{max_chars}) && "$args{max_chars}" =~ /^\d+\z/
        ? int($args{max_chars}) : 700;
    $max = 80 if $max < 80;
    $max = 2000 if $max > 2000;

    my $text = _clean_line($args{text}, $max);
    return { ok => 0, reason => 'invalid_input' } unless defined $text;

    my $speaker = _plain($args{speaker}) ? "$args{speaker}" : '';
    my $bot_nick = _plain($args{bot_nick}) ? "$args{bot_nick}" : '';
    my @nicks = _nick_list([
        @{ ref($args{nicks}) eq 'ARRAY' ? $args{nicks} : [] },
        grep { length($_) } ($speaker, $bot_nick),
    ]);

    $text = _strip_paste_prefixes($text, \@nicks);
    if (length($bot_nick)) {
        my $quoted = quotemeta($bot_nick);
        $text =~ s/^\s*\@?$quoted\s*(?:>+|[,:~.]|\s)\s*//iu;
    }
    $text =~ s/^\s+|\s+$//g;
    $text =~ s/\s{2,}/ /g;
    return { ok => 0, reason => 'empty_after_normalization' } unless length($text);

    my @prefixes = ref($args{command_prefixes}) eq 'ARRAY'
        ? grep { _plain($_) && length($_) == 1 } @{ $args{command_prefixes} }
        : ('!');
    my $is_command = _is_command($text, \@prefixes);

    my %bucket_nicks;
    my $target_nick;
    for my $nick (@nicks) {
        my $replacement;
        if (length($bot_nick) && _irc_fold($nick) eq _irc_fold($bot_nick)) {
            $replacement = $SELF_TOKEN;
        }
        elsif (length($speaker) && _irc_fold($nick) eq _irc_fold($speaker)) {
            $replacement = $SPEAKER_TOKEN;
        }
        else {
            $replacement = hailo_placeholder_for_nick(
                channel => $args{channel},
                nick    => $nick,
            );
            push @{ $bucket_nicks{$replacement} }, $nick if defined $replacement;
        }
        next unless defined($replacement);

        my $pattern = _nick_pattern($nick);
        if ($text =~ /$pattern/u) {
            $target_nick //= $nick
                unless length($speaker) && _irc_fold($nick) eq _irc_fold($speaker);
            $text =~ s/$pattern/$replacement/gu;
        }
    }

    $text =~ s/^\s+|\s+$//g;
    $text =~ s/\s{2,}/ /g;
    return { ok => 0, reason => 'empty_after_placeholders' } unless length($text);

    return {
        ok               => 1,
        text             => $text,
        is_command       => $is_command ? 1 : 0,
        command_prefixes => \@prefixes,
        speaker_token    => $SPEAKER_TOKEN,
        self_token       => $SELF_TOKEN,
        bucket_nicks     => \%bucket_nicks,
        target_nick      => $target_nick,
        channel_key      => $channel,
    };
}

sub rehydrate_hailo_output {
    my (%args) = @_;
    my $max = _plain($args{max_chars}) && "$args{max_chars}" =~ /^\d+\z/
        ? int($args{max_chars}) : 360;
    $max = 40 if $max < 40;
    $max = 1000 if $max > 1000;

    my $line = _clean_line($args{text}, $max);
    return { ok => 0, reason => 'invalid_output' } unless defined $line;

    my $speaker = _plain($args{speaker}) ? "$args{speaker}" : '';
    my $bot_nick = _plain($args{bot_nick}) ? "$args{bot_nick}" : '';
    my @nicks = _nick_list([
        @{ ref($args{nicks}) eq 'ARRAY' ? $args{nicks} : [] },
        grep { length($_) } ($speaker, $bot_nick),
    ]);

    # MegaHAL's historic nickswitch behaviour is retained: references to the
    # bot itself become references to the current interlocutor when possible.
    my $self_replacement = length($speaker) ? $speaker : $bot_nick;
    $line =~ s/\Q$SELF_TOKEN\E/$self_replacement/giu if length($self_replacement);
    $line =~ s/\Q$SPEAKER_TOKEN\E/$speaker/giu if length($speaker);

    my %buckets;
    for my $nick (@nicks) {
        next if length($bot_nick) && _irc_fold($nick) eq _irc_fold($bot_nick);
        my $token = hailo_placeholder_for_nick(
            channel => $args{channel},
            nick    => $nick,
        );
        push @{ $buckets{$token} }, $nick if defined $token;
    }
    if (ref($args{bucket_nicks}) eq 'HASH') {
        for my $token (keys %{ $args{bucket_nicks} }) {
            next unless $token =~ /^\Q$NICK_PREFIX\E\d{2}\Q$NICK_SUFFIX\E\z/;
            for my $nick (@{ ref($args{bucket_nicks}{$token}) eq 'ARRAY'
                    ? $args{bucket_nicks}{$token} : [] }) {
                push @{ $buckets{$token} }, $nick if _plain($nick) && length($nick);
            }
        }
    }

    $line =~ s{\b\Q$NICK_PREFIX\E(\d{2})\Q$NICK_SUFFIX\E\b}{
        my $token = sprintf('%s%02d%s', $NICK_PREFIX, $1, $NICK_SUFFIX);
        my @pool = _nick_list($buckets{$token});
        @pool ? $pool[0] : (length($speaker) ? $speaker : '');
    }geiu;

    # Restore the exact current casing of visible nicks.
    for my $nick (@nicks) {
        my $pattern = _nick_pattern($nick);
        $line =~ s/$pattern/$nick/giu;
    }

    $line =~ s/^\s+|\s+$//g;
    $line =~ s/\s{2,}/ /g;
    return { ok => 0, reason => 'empty_output' } unless length($line);
    return { ok => 0, reason => 'oversized_output' } if length($line) > $max;

    my @prefixes = ref($args{command_prefixes}) eq 'ARRAY'
        ? @{ $args{command_prefixes} } : ('!');
    return { ok => 0, reason => 'command_output' }
        if _is_command($line, \@prefixes);

    return { ok => 1, line => $line, reason => 'accepted' };
}

1;
