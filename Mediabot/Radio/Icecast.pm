package Mediabot::Radio::Icecast;

use strict;
use warnings;

use HTTP::Tiny;
use JSON::MaybeXS qw(decode_json);
use POSIX qw(isfinite);

our $VERSION = '0.02';

sub new {
    my ($class, %args) = @_;

    my $timeout = defined $args{timeout} ? $args{timeout} : 5;
    $timeout =~ s/^\s+|\s+\z//g if defined $timeout;
    $timeout = 5 unless defined($timeout) && $timeout =~ /^\d+(?:\.\d+)?\z/ && $timeout > 0;
    $timeout = 1  if $timeout < 1;
    $timeout = 30 if $timeout > 30;

    my $self = bless {
        base_url => $args{base_url} || 'http://127.0.0.1:8000',
        timeout  => $timeout,
        logger   => $args{logger},
        ua       => undef,
    }, $class;

    $self->{base_url} =~ s{/\z}{};

    # B1/A1: accept pre-built ua handle (e.g. from External::_make_http)
    $self->{ua} = $args{ua} // HTTP::Tiny->new(
        timeout => $self->{timeout},
        agent   => "Mediabot-Radio-Icecast/$VERSION",
    );

    return $self;
}

sub get_status {
    my ($self) = @_;

    my $stats = $self->_fetch_icestats();
    return $stats unless $stats->{ok};

    return _status_from_icestats($stats->{icestats});
}

sub _status_from_icestats {
    my ($icestats) = @_;
    return {
        ok        => 1,
        host      => _scalar($icestats->{host}),
        admin     => _scalar($icestats->{admin}),
        location  => _scalar($icestats->{location}),
        server_id => _scalar($icestats->{server_id}),
        sources   => _num($icestats->{sources}),
        listeners => _num($icestats->{listeners}),
        started   => _scalar($icestats->{server_start_iso8601}) || _scalar($icestats->{server_start}),
        raw       => $icestats,
    };
}

sub get_listeners {
    my ($self) = @_;

    my $mounts = $self->get_mounts();
    return $mounts unless $mounts->{ok};

    return _listeners_from_mounts($mounts);
}

sub _listeners_from_mounts {
    my ($mounts) = @_;
    my %per_mount;
    my $total = 0;

    for my $m (@{ $mounts->{mounts} }) {
        my $listeners = _num($m->{listeners});
        $per_mount{ $m->{mount} } = $listeners;
        $total += $listeners;
    }

    return {
        ok        => 1,
        total     => $total,
        per_mount => \%per_mount,
    };
}

sub get_now_playing {
    my ($self) = @_;

    my $mounts = $self->get_mounts();
    return $mounts unless $mounts->{ok};

    my %per_mount;
    my %seen;
    my $title = '';

    for my $m (@{ $mounts->{mounts} }) {
        my $t = defined $m->{title} ? $m->{title} : '';
        $per_mount{ $m->{mount} } = $t;
        $seen{$t}++ if $t ne '';
    }

    if (keys %seen == 1) {
        ($title) = keys %seen;
    }
    else {
        for my $m (@{ $mounts->{mounts} }) {
            if (defined $m->{title} && $m->{title} ne '') {
                $title = $m->{title};
                last;
            }
        }
    }

    return {
        ok        => 1,
        title     => $title,
        per_mount => \%per_mount,
    };
}

sub get_primary_mount_status {
    my ($self, %args) = @_;

    my $stats = $self->_fetch_icestats();
    return $stats unless $stats->{ok};
    my $mounts = $self->_mounts_from_icestats($stats->{icestats});
    return $self->_primary_from_snapshot($stats->{icestats}, $mounts, %args);
}

# Derived views must share one response. Fetching each view separately can
# combine a former title/server with new mounts or listener counts.
sub _primary_from_snapshot {
    my ($self, $icestats, $mounts, %args) = @_;
    my $primary_mount = $args{primary_mount} || '/radio.mp3';
    my $public_base   = $args{public_base}   || $self->{base_url};
    $public_base =~ s{/\z}{};
    my $status = _status_from_icestats($icestats);
    my $listeners = _listeners_from_mounts($mounts);

    my ($selected) = grep {
        defined $_->{mount} && $_->{mount} eq $primary_mount
    } @{ $mounts->{mounts} || [] };

    $selected ||= $mounts->{mounts}[0] if @{ $mounts->{mounts} || [] };

    unless ($selected) {
        return {
            ok    => 0,
            error => 'No Icecast mount available',
        };
    }

    my $mount = $selected->{mount} || '';
    my $title = defined $selected->{title} ? $selected->{title} : '';

    return {
        ok                => 1,
        host              => $status->{host},
        server_id         => $status->{server_id},
        sources           => $status->{sources},
        total_listeners   => $listeners->{total},
        primary_mount     => $mount,
        bitrate           => $selected->{bitrate},
        mount_listeners   => $selected->{listeners},
        title             => $title,
        listen_url        => $public_base . $mount,
        description       => $selected->{description},
        server_url        => $selected->{server_url},
        listenurl_raw     => $selected->{listenurl},
        mount_info        => $selected,
        status_info       => $status,
    };
}

sub get_summary {
    my ($self, %args) = @_;

    my $stats = $self->_fetch_icestats();
    return $stats unless $stats->{ok};
    my $mounts = $self->_mounts_from_icestats($stats->{icestats});
    my $primary = $self->_primary_from_snapshot($stats->{icestats}, $mounts, %args);
    return $primary unless $primary->{ok};

    return {
        ok              => 1,
        host            => $primary->{host},
        server_id       => $primary->{server_id},
        sources         => $primary->{sources},
        total_listeners => $primary->{total_listeners},
        primary_mount   => $primary->{primary_mount},
        bitrate         => $primary->{bitrate},
        mount_listeners => $primary->{mount_listeners},
        title           => $primary->{title},
        listen_url      => $primary->{listen_url},
        description     => $primary->{description},
        server_url      => $primary->{server_url},
        mounts          => $mounts->{mounts},
    };
}

sub get_mounts {
    my ($self) = @_;

    my $stats = $self->_fetch_icestats();
    return $stats unless $stats->{ok};

    return $self->_mounts_from_icestats($stats->{icestats});
}

sub _mounts_from_icestats {
    my ($self, $icestats) = @_;
    my $sources = $icestats->{source};

    my @mounts;

    if (ref($sources) eq 'ARRAY') {
        @mounts = map { $self->_normalize_mount($_) }
          grep { ref($_) eq 'HASH' } @$sources;
    }
    elsif (ref($sources) eq 'HASH') {
        @mounts = ($self->_normalize_mount($sources));
    }
    else {
        @mounts = ();
    }

    @mounts = sort {
        ($a->{mount} || '') cmp ($b->{mount} || '')
    } @mounts;

    return {
        ok     => 1,
        mounts => \@mounts,
    };
}

sub _fetch_icestats {
    my ($self) = @_;

    my $url = $self->{base_url} . '/status-json.xsl';

    my $res = eval { $self->{ua}->get($url) }
           // { success => 0, status => 0, reason => $@ };

    if (!$res->{success}) {
        my $status = join ' ',
          grep { defined($_) && $_ ne '' }
          ($res->{status}, $res->{reason});
        $status ||= 'unknown HTTP error';

        $self->_log(1, "Icecast fetch failed for $url: $status");
        return {
            ok    => 0,
            error => "HTTP error: $status",
        };
    }

    my $content = $res->{content} // '';
    unless ($content ne '') {
        $self->_log(1, "Icecast empty response for $url");
        return {
            ok    => 0,
            error => "Empty Icecast response",
        };
    }

    my $decoded;
    eval {
        $decoded = decode_json($content);
        1;
    } or do {
        my $err = $@ || 'unknown JSON error';
        $self->_log(1, "Icecast JSON decode failed for $url: $err");
        return {
            ok    => 0,
            error => "JSON decode failed: $err",
        };
    };

    if (!ref($decoded) || ref($decoded) ne 'HASH' || ref($decoded->{icestats}) ne 'HASH') {
        $self->_log(1, "Icecast response for $url does not contain icestats hash");
        return {
            ok    => 0,
            error => "Invalid Icecast JSON structure",
        };
    }

    return {
        ok       => 1,
        icestats => $decoded->{icestats},
    };
}

sub _normalize_mount {
    my ($self, $src) = @_;

    return {
        mount => '',
        title => '',
        raw   => $src,
    } unless ref($src) eq 'HASH';

    my $mount = '';
    my $listenurl = _scalar($src->{listenurl});
    my $server_name = _scalar($src->{server_name});

    if (defined $listenurl && $listenurl =~ m{https?://[^/]+(/.*)\z}) {
        $mount = $1;
    }
    elsif (defined $server_name && $server_name ne '') {
        $mount = $server_name;
        $mount = "/$mount" unless $mount =~ m{^/};
    }

    return {
        mount            => $mount,
        server_name      => $server_name,
        description      => _scalar($src->{server_description}),
        listenurl        => $listenurl,
        server_url       => _scalar($src->{server_url}),
        title            => _scalar($src->{title}) // '',
        bitrate          => _num($src->{bitrate}),
        samplerate       => _num($src->{samplerate}),
        channels         => _num($src->{channels}),
        listeners        => _num($src->{listeners}),
        listener_peak    => _num($src->{listener_peak}),
        source_ip        => $src->{source_ip},
        stream_start     => _scalar($src->{stream_start_iso8601}) || _scalar($src->{stream_start}),
        server_type      => $src->{server_type},
        audio_info       => $src->{audio_info},
        user_agent       => $src->{user_agent},
        raw              => $src,
    };
}

# Optional display fields must not stringify JSON containers or booleans.
# Keep valid scalars and the original raw snapshot available to callers.
sub _scalar {
    return ref($_[0]) ? undef : $_[0];
}

sub _num {
    my ($v) = @_;

    return 0 unless defined $v && !ref($v);

    $v =~ s/^\s+|\s+\z//g;
    $v =~ s/,//g;

    return 0 unless $v =~ /^\d+(?:\.\d+)?\z/;

    my $number = 0 + $v;
    return isfinite($number) ? int($number) : 0;
}

sub _log {
    my ($self, $level, $msg) = @_;
    return unless $self->{logger};

    eval {
        $self->{logger}->log($level, $msg);
        1;
    };

    return;
}

1;

__END__

=pod

=head1 NAME

Mediabot::Radio::Icecast - minimal Icecast status reader for Mediabot

=head1 SYNOPSIS

    use Mediabot::Radio::Icecast;

    my $radio = Mediabot::Radio::Icecast->new(
        base_url => 'http://127.0.0.1:8000',
        timeout  => 5,
        logger   => $logger,
    );

    my $status    = $radio->get_status();
    my $mounts    = $radio->get_mounts();
    my $np        = $radio->get_now_playing();
    my $listeners = $radio->get_listeners();

=head1 DESCRIPTION

Small helper module to read Icecast runtime information from status-json.xsl
and expose simple Perl data structures usable by Mediabot.

=head1 METHODS

=head2 new

Constructor.

=head2 get_status

Returns a global status hash.

=head2 get_listeners

Returns total listeners and listeners per mount.

=head2 get_now_playing

Returns current title globally and per mount.

=head2 get_mounts

Returns normalized mount information.

=cut