package Mediabot::RSS::Poller;

use strict;
use warnings;
use utf8;

use Mediabot::RSS qw(rss_publication_epoch);
use Mediabot::RSS::Fetcher;

sub new {
    my ($class, %args) = @_;
    die "repo is required" unless $args{repo};
    return bless {
        repo    => $args{repo},
        pacing  => $args{pacing},
        fetcher => $args{fetcher} || \&Mediabot::RSS::Fetcher::fetch_feed_once,
    }, $class;
}

sub repo { $_[0]->{repo} }

sub _clean_error {
    my ($res) = @_;
    my $err = ref($res) eq 'HASH' ? ($res->{error} // 'unknown') : 'unknown';
    my $detail = ref($res) eq 'HASH' ? ($res->{detail} // '') : '';
    my $text = length($detail) ? "$err: $detail" : $err;
    $text =~ s/[\r\n\0]+/ /g;
    return substr($text, 0, 255);
}

sub poll_feed {
    my ($self, $feed) = @_;
    return { ok => 0, error => 'invalid_feed' }
        unless ref($feed) eq 'HASH'
        && defined($feed->{id_rss_feed}) && $feed->{id_rss_feed} =~ /^\d+$/
        && defined($feed->{url}) && !ref($feed->{url});

    my $paced = 0;
    if ($self->{pacing}) {
        my $policy = eval { $self->{pacing}->status($feed->{channel}) };
        return {ok => 0, error => 'pacing_state'} unless $policy;
        $paced = $policy->{active};
    }
    my $id = 0 + $feed->{id_rss_feed};
    my $limit = int($feed->{announce_limit} || 5);
    $limit = 1 if $limit < 1;
    $limit = 10 if $limit > 10;
    $limit = 1 if $paced;
    my $baseline = defined($feed->{last_success_at}) && length($feed->{last_success_at}) ? 0 : 1;

    my $res = eval {
        $self->{fetcher}->(
            $feed->{url},
            max_items     => 100,
            etag          => $baseline ? undef : $feed->{etag},
            last_modified => $baseline ? undef : $feed->{last_modified},
        );
    };
    if (!$res || ref($res) ne 'HASH') {
        my $detail = $@ || 'fetcher returned no result';
        my $err = { error => 'fetch_exception', detail => $detail };
        my $recorded = eval { $self->repo->record_poll_error($id, _clean_error($err)) };
        return { ok => 0, %$err, error_recorded => $recorded ? 1 : 0 };
    }

    # Only a complete feed body can establish the silent baseline.
    if ($baseline && $res->{ok} && $res->{not_modified}) {
        $res = { ok => 0, error => 'unexpected_not_modified', status => 304 };
    }

    if (!$res->{ok}) {
        my $error = _clean_error($res);
        my $recorded = eval { $self->repo->record_poll_error($id, $error) };
        return { %$res, ok => 0, error_recorded => $recorded ? 1 : 0 };
    }

    if ($res->{not_modified}) {
        my $ok = eval {
            $self->repo->record_not_modified(
                $id,
                etag          => $res->{etag},
                last_modified => $res->{last_modified},
            );
            1;
        };
        return { ok => 0, error => 'repository_error', detail => $@ } unless $ok;
        my $pending = eval { $paced ? $self->repo->paced_pending_items($id) : $self->repo->pending_items($id, $limit) };
        return { ok => 0, error => 'repository_error', detail => $@ } if $@;
        return {
            ok           => 1,
            not_modified => 1,
            baseline     => 0,
            inserted     => 0,
            pending      => $pending || [],
        };
    }

    my $items = $res->{feed}{items};
    $items = [] unless ref($items) eq 'ARRAY';
    if ($paced && !$baseline) {
        # The first new linked entry gets the slot. Rank dated entries first
        # without changing feed order among ties or undated entries.
        my @published = map {
            [$_, ref($_) eq 'HASH' ? rss_publication_epoch($_->{published}) : undef]
        } @$items;
        $items = [map { $_->[0] } sort {
            defined($b->[1]) <=> defined($a->[1])
                || ($b->[1] // 0) <=> ($a->[1] // 0)
        } @published];
    }
    my $new = 0;
    my $stored = 0;

    my $persist_ok = eval {
        for my $item (@$items) {
            next unless ref($item) eq 'HASH';
            # Keep linkless items for deduplication without using a delivery slot.
            my $url = $item->{url};
            my $suppress = $baseline || $new >= $limit
                || !defined($url) || ref($url) || !length($url);
            my $inserted = $self->repo->insert_item(
                $id, $item, announced => ($suppress ? 1 : 0)
            );
            next unless $inserted;
            $stored++;
            $new++ unless $suppress;
        }
        $self->repo->record_poll_success(
            $id,
            etag          => $res->{etag},
            last_modified => $res->{last_modified},
        );
        1;
    };
    return { ok => 0, error => 'repository_error', detail => $@ }
        unless $persist_ok;

    my $pending = $baseline ? [] : eval { $paced ? $self->repo->paced_pending_items($id) : $self->repo->pending_items($id, $limit) };
    return { ok => 0, error => 'repository_error', detail => $@ } if $@;

    return {
        ok           => 1,
        status       => $res->{status},
        baseline     => $baseline,
        inserted     => $stored,
        pending      => $pending || [],
        etag         => $res->{etag},
        last_modified => $res->{last_modified},
    };
}

1;
