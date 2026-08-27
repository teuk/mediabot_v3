package Mediabot::VDM;

use strict;
use warnings;
use utf8;

use Exporter qw(import);
use Encode qw(encode);

our @EXPORT_OK = qw(
    vdm_feed_url
    vdm_chanset_name
    vdm_repeat_window_seconds
    evaluate_vdm_gate
    vdm_item_id
    format_vdm_line
);

use constant VDM_FEED_URL       => 'https://www.viedemerde.fr/feeds/articles';
use constant VDM_CHANSET_NAME   => 'VDM';
use constant VDM_REPEAT_SECONDS => 120;
use constant VDM_MAX_VISIBLE    => 350;
use constant VDM_MAX_WIRE_BYTES => 400;

sub vdm_feed_url {
    return VDM_FEED_URL;
}

sub vdm_chanset_name {
    return VDM_CHANSET_NAME;
}

sub vdm_repeat_window_seconds {
    return VDM_REPEAT_SECONDS;
}

sub evaluate_vdm_gate {
    my (%args) = @_;

    my $mode = defined($args{mode}) ? lc($args{mode}) : '';
    return { action => 'skip', reason => 'invalid_mode' }
        unless $mode eq 'manual' || $mode eq 'spark';

    my $channel = $args{channel};
    return { action => 'skip', reason => 'private_target' }
        unless defined($channel) && !ref($channel) && $channel =~ /^#/;

    return { action => 'skip', reason => 'runtime_inactive' }
        if exists($args{runtime_active}) && !$args{runtime_active};

    return { action => 'skip', reason => 'irc_disconnected' }
        if exists($args{irc_connected}) && !$args{irc_connected};

    return { action => 'skip', reason => 'not_joined' }
        if exists($args{channel_joined}) && !$args{channel_joined};

    return { action => 'skip', reason => 'vdm_disabled' }
        unless $args{vdm_enabled};

    if ($mode eq 'spark' && !$args{spark_enabled}) {
        return { action => 'skip', reason => 'spark_disabled' };
    }

    return {
        action => 'allow',
        reason => $mode eq 'spark' ? 'spark_vdm_enabled' : 'manual_vdm_enabled',
        mode   => $mode,
    };
}

sub vdm_item_id {
    my ($item) = @_;
    return undef unless ref($item) eq 'HASH';

    if (defined($item->{id}) && !ref($item->{id}) && $item->{id} =~ /\A([0-9]+)\z/) {
        return $1;
    }

    for my $field (qw(guid url)) {
        my $value = $item->{$field};
        next unless defined($value) && !ref($value);

        return $1 if $value =~ /_([0-9]+)\.html(?:[?#].*)?\z/i;
        return $1 if $value =~ m{/([0-9]+)\.html(?:[?#].*)?\z}i;
        return $1 if $value =~ /(?:\A|[?&])(?:id|article)=([0-9]+)(?:[&#]|\z)/i;
        return $1 if $value =~ /#([0-9]+)\z/;
    }

    return undef;
}

sub _safe_scalar {
    my ($value) = @_;
    return undef unless defined($value) && !ref($value);
    return undef if $value eq '';
    return undef if $value =~ /[\x00-\x1f\x7f]/;
    return $value;
}

sub format_vdm_line {
    my (%args) = @_;

    my $id = _safe_scalar($args{id});
    return undef unless defined($id) && $id =~ /\A[0-9]+\z/;

    my $story = _safe_scalar($args{story});
    return undef unless defined $story;

    # Keep the published closing marker; do not silently rewrite source text.
    return undef unless $story =~ /VDM\z/i;

    my $visible = "[$id] $story";
    return undef if length($visible) > VDM_MAX_VISIBLE;

    my $id_part    = "\x02\x03" . "01,15" . "[$id]" . "\x0f";
    my $story_part = "\x03" . "00,14" . $story . "\x0f";
    my $line = "$id_part $story_part";

    return undef if length(encode("UTF-8", $line)) > VDM_MAX_WIRE_BYTES;
    return $line;
}

1;
