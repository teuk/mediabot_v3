package Mediabot::AI::Transport;

use strict;
use warnings;

use Carp qw(croak);
use Exporter 'import';
use MIME::Base64 qw(encode_base64 decode_base64);

our $VERSION = '1.0';
our @EXPORT_OK = qw(
    usable_loop
    post_json
    decode_content
);

sub usable_loop {
    my ($owner) = @_;

    my $loop = eval {
        (ref($owner) && $owner->can('getLoop'))
            ? $owner->getLoop
            : undef;
    };
    $loop ||= eval { $owner->{loop} };

    return undef unless $loop
        && eval { $loop->can('add') }
        && eval { $loop->can('remove') }
        && eval { $loop->can('watch_process') };

    return $loop;
}

sub _clean_reason {
    my ($value) = @_;
    $value = '' unless defined($value) && !ref($value);
    $value = "$value";
    $value =~ s/[\r\n\0]+/ /g;
    return substr($value, 0, 300);
}

sub post_json {
    my (%args) = @_;

    croak 'api_url is required'
        unless defined($args{api_url}) && !ref($args{api_url})
            && length($args{api_url});
    croak 'timeout must be a positive number'
        unless defined($args{timeout}) && !ref($args{timeout})
            && $args{timeout} =~ /^\d+(?:\.\d+)?\z/
            && $args{timeout} > 0;
    croak 'headers must be a hash reference'
        unless ref($args{headers}) eq 'HASH';
    croak 'payload must be a scalar'
        unless defined($args{payload}) && !ref($args{payload});
    croak 'http_factory must be a code reference'
        unless ref($args{http_factory}) eq 'CODE';

    my $http = eval {
        $args{http_factory}->(
            timeout    => 0 + $args{timeout},
            verify_SSL => 1,
        );
    };
    if (!$http || !eval { $http->can('request') }) {
        my $reason = $@ || 'HTTP client factory failed';
        return {
            success     => 0,
            status      => 0,
            reason      => _clean_reason($reason),
            content_b64 => '',
        };
    }

    my $res = eval {
        $http->request(
            'POST',
            $args{api_url},
            {
                headers => $args{headers},
                content => $args{payload},
            }
        );
    };

    if (!$res || ref($res) ne 'HASH') {
        my $reason = $@ || 'invalid HTTP response';
        return {
            success     => 0,
            status      => 0,
            reason      => _clean_reason($reason),
            content_b64 => '',
        };
    }

    my $status = $res->{status};
    $status = 0 if !defined($status) || ref($status);

    my $content = $res->{content};
    $content = '' if !defined($content) || ref($content);

    return {
        success     => $res->{success} ? 1 : 0,
        status      => "$status",
        reason      => _clean_reason($res->{reason}),
        content_b64 => encode_base64($content, ''),
    };
}

sub decode_content {
    my ($result) = @_;
    return '' unless ref($result) eq 'HASH';

    my $content = eval { decode_base64($result->{content_b64} // '') };
    return defined($content) ? $content : '';
}

1;
