package Mediabot::Spark::Event;

use strict;
use warnings;

use Carp qw(croak);
use Exporter 'import';

our $VERSION = '1.0';
our @EXPORT_OK = qw(
    spark_event_kinds
    spark_event_profile
    spark_event_requires_response
    spark_event_is_momentum
    spark_event_is_selectable
    spark_event_catalog_summary
);

my %PROFILE = (
    fork => {
        duration_seconds => 60,
        min_recent_humans => 2,
        needs_context => 0,
        ai_use => 'optional',
        interaction => 'choice',
        requires_response => 1,
        lane => 'retired',
        selectable => 0,
    },
    portal => {
        duration_seconds => 75,
        min_recent_humans => 3,
        needs_context => 0,
        ai_use => 'optional',
        interaction => 'contributions',
        requires_response => 1,
        lane => 'revival',
        selectable => 1,
    },
    mosaic => {
        duration_seconds => 75,
        min_recent_humans => 2,
        needs_context => 0,
        ai_use => 'required',
        interaction => 'word_mosaic',
        requires_response => 1,
        delivery_style => 'message',
        lane => 'retired',
        selectable => 0,
    },
    callback => {
        duration_seconds => 45,
        min_recent_humans => 2,
        needs_context => 1,
        ai_use => 'preferred',
        interaction => 'conversation',
        requires_response => 0,
        lane => 'revival',
        selectable => 1,
    },
    reaction => {
        duration_seconds => 45,
        min_recent_humans => 2,
        needs_context => 1,
        ai_use => 'preferred',
        interaction => 'conversation',
        requires_response => 0,
        delivery_style => 'message',
        lane => 'revival',
        selectable => 1,
    },
    aside => {
        duration_seconds => 45,
        min_recent_humans => 1,
        needs_context => 0,
        ai_use => 'required',
        interaction => 'autonomous_aside',
        requires_response => 0,
        delivery_style => 'message',
        lane => 'revival',
        selectable => 1,
    },
    micro_scene => {
        duration_seconds => 45,
        min_recent_humans => 1,
        needs_context => 0,
        ai_use => 'required',
        interaction => 'autonomous_scene',
        requires_response => 0,
        delivery_style => 'message',
        lane => 'revival',
        selectable => 1,
    },
    stage_cue => {
        duration_seconds => 45,
        min_recent_humans => 3,
        needs_context => 1,
        ai_use => 'required',
        interaction => 'ambient_action',
        requires_response => 0,
        delivery_style => 'action',
        lane => 'momentum',
        selectable => 1,
    },
    afterglow => {
        duration_seconds => 45,
        min_recent_humans => 3,
        needs_context => 1,
        ai_use => 'required',
        interaction => 'ambient_epilogue',
        requires_response => 0,
        delivery_style => 'message',
        lane => 'momentum',
        selectable => 1,
    },
    vdm => {
        duration_seconds => 45,
        min_recent_humans => 3,
        needs_context => 0,
        ai_use => 'never',
        interaction => 'story',
        requires_response => 0,
        delivery_style => 'message',
        lane => 'revival',
        selectable => 1,
    },
);

$PROFILE{fork}{delivery_style} = 'message';
$PROFILE{portal}{delivery_style} = 'message';
$PROFILE{callback}{delivery_style} = 'message';

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
    return [ qw(fork portal callback reaction mosaic aside micro_scene stage_cue afterglow vdm) ];
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

sub spark_event_requires_response {
    my ($kind) = @_;
    $kind = _kind($kind);
    croak 'unknown Spark event kind' unless defined $kind;
    return $PROFILE{$kind}{requires_response} ? 1 : 0;
}

sub spark_event_is_momentum {
    my ($kind) = @_;
    $kind = _kind($kind);
    croak 'unknown Spark event kind' unless defined $kind;
    return ($PROFILE{$kind}{lane} // '') eq 'momentum' ? 1 : 0;
}

sub spark_event_is_selectable {
    my ($kind) = @_;
    $kind = _kind($kind);
    croak 'unknown Spark event kind' unless defined $kind;
    return $PROFILE{$kind}{selectable} ? 1 : 0;
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
            requires_response  => $p->{requires_response} ? 1 : 0,
            delivery_style     => "$p->{delivery_style}",
            lane               => "$p->{lane}",
            selectable         => $p->{selectable} ? 1 : 0,
        };
    }
    return \@out;
}

1;
