package Mediabot::Plugin::ShortContent;

use strict;
use warnings;
use utf8;

use Encode qw(encode);
use JSON::PP ();

sub new {
    my ($class, %args) = @_;
    return bless { context => $args{context}, started => 0 }, $class;
}

sub start { $_[0]{started} = 1; 1 }
sub stop  { $_[0]{started} = 0; 1 }

sub _message {
    my ($invocation, $key) = @_;
    my $language = $invocation->config_value('language') || 'fr';
    my %messages = (
        fr => {
            unavailable => 'Le petit messager externe est indisponible pour le moment.',
            malformed   => q{Le petit messager a répondu, mais son message n'était pas exploitable.},
        },
        en => {
            unavailable => 'The little external messenger is unavailable right now.',
            malformed   => 'The little messenger replied, but its message was not usable.',
        },
    );
    return $messages{$language}{$key} || $messages{en}{$key};
}

sub _value_at_path {
    my ($document, $path) = @_;
    return undef unless defined($path) && !ref($path)
        && $path =~ /\A[a-zA-Z0-9_-]+(?:\.[a-zA-Z0-9_-]+){0,3}\z/;
    my $value = $document;
    for my $part (split /\./, $path) {
        return undef unless ref($value) eq 'HASH' && exists $value->{$part};
        $value = $value->{$part};
    }
    return undef if !defined($value) || ref($value);
    return "$value";
}

sub _bounded_text {
    my ($text, $max_chars, $max_bytes) = @_;
    return undef unless defined($text) && !ref($text);
    $text = "$text";
    $text =~ s/[\x00-\x1f\x7f]//g;
    $text =~ s/\s+/ /g;
    $text =~ s/^\s+|\s+$//g;
    return undef unless length $text;
    $text = substr($text, 0, $max_chars) if length($text) > $max_chars;
    while (length($text) && length(encode('UTF-8', $text)) > $max_bytes) {
        chop $text;
    }
    return length($text) ? $text : undef;
}

sub _record_success {
    my ($self, $context, $invocation, $text) = @_;
    my $snapshot = eval { $context->storage_snapshot($invocation) };
    return unless ref($snapshot) eq 'HASH'
        && !defined($snapshot->{error})
        && ref($snapshot->{values}) eq 'HASH';
    my $served = $snapshot->{values}{served};
    $served = 0 unless defined($served) && !ref($served)
        && "$served" =~ /\A[0-9]+\z/;
    $served++;
    eval {
        $context->storage_commit($invocation,
            expected_revision => $snapshot->{revision},
            changes => {
                last   => $text,
                served => "$served",
            },
        );
        1;
    };
    return;
}

sub command_short {
    my ($self, $context, $invocation) = @_;
    my $endpoint = $invocation->config_value('endpoint');
    my $ttl = $invocation->config_value('cache_ttl_seconds');
    return $context->http_fetch($invocation, {
        url               => $endpoint,
        timeout_seconds   => 5,
        cache_ttl_seconds => defined($ttl) ? $ttl : 300,
        max_bytes         => 32768,
        accept            => 'application/json',
    }, sub {
        my ($response) = @_;
        unless ($response && $response->ok) {
            return $context->reply($invocation,
                _message($invocation, 'unavailable'));
        }
        my $document = eval { JSON::PP->new->decode($response->body) };
        unless (ref($document) eq 'HASH') {
            return $context->reply($invocation,
                _message($invocation, 'malformed'));
        }
        my $path = $invocation->config_value('json_path') || 'text';
        my $max_chars = $invocation->config_value('max_chars') || 280;
        my $prefix = $invocation->config_value('prefix') // '';
        my $value = _value_at_path($document, $path);
        my $prefix_bytes = length(encode('UTF-8', $prefix));
        my $text = _bounded_text($value, $max_chars,
            400 - ($prefix_bytes < 400 ? $prefix_bytes : 400));
        unless (defined $text) {
            return $context->reply($invocation,
                _message($invocation, 'malformed'));
        }
        $self->_record_success($context, $invocation, $text);
        return $context->reply($invocation, $prefix . $text);
    });
}

1;
