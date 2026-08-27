package Mediabot::Spark::Event;

use strict;
use warnings;

use Carp qw(croak);
use Exporter 'import';

our $VERSION = '1.0';
our @EXPORT_OK = qw(
    spark_event_kinds
    spark_event_profile
    spark_event_catalog_summary
);

my %PROFILE = (
    fork => {
        duration_seconds => 60,
        min_recent_humans => 2,
        needs_context => 0,
        ai_use => 'optional',
        interaction => 'choice',
    },
    portal => {
        duration_seconds => 75,
        min_recent_humans => 3,
        needs_context => 0,
        ai_use => 'optional',
        interaction => 'contributions',
    },
    callback => {
        duration_seconds => 45,
        min_recent_humans => 2,
        needs_context => 1,
        ai_use => 'preferred',
        interaction => 'conversation',
    },
);

sub _plain_scalar {
    my ($value) = @_;
    return defined($value) && !ref($value);
}

sub _kind {
    my ($kind) = @_;
    return undef unless _plain_scalar($kind);
    $kind = lc "$kind";
    return exists($PROFILE{$kind}) ? $kind : undef;
}

sub spark_event_kinds {
    return [ qw(fork portal callback) ];
}

sub spark_event_profile {
    my ($kind) = @_;
    $kind = _kind($kind);
    croak 'unknown Spark event kind' unless defined $kind;
    return {
        kind => $kind,
        %{ $PROFILE{$kind} },
    };
}

sub spark_event_catalog_summary {
    my @out;
    for my $kind (@{ spark_event_kinds() }) {
        my $p = spark_event_profile($kind);
        push @out, {
            kind               => $p->{kind},
            duration_seconds   => int($p->{duration_seconds}),
            min_recent_humans  => int($p->{min_recent_humans}),
            needs_context      => $p->{needs_context} ? 1 : 0,
            ai_use             => "$p->{ai_use}",
            interaction        => "$p->{interaction}",
        };
    }
    return \@out;
}

1;
