#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use File::Spec;

sub _slurp_1021 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path
        or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $roadmap = _slurp_1021(
        File::Spec->catfile('.', 'docs', 'ROADMAP_3.5.md')
    );
    my $design = _slurp_1021(
        File::Spec->catfile('.', 'docs', 'HAILO_3.5.md')
    );

    $assert->like(
        $roadmap,
        qr/\| MB720 \| P0 \|[^\n]*Hailo[^\n]*per-channel[^\n]*post-editor/i,
        'MB720 is an explicit P0 Hailo release gate',
    );
    $assert->like(
        $roadmap,
        qr/Mediabot 3[.]5[^\n]*(?:must not|cannot)[^\n]*release[^\n]*Hailo/is,
        'roadmap blocks 3.5 until Hailo is qualified',
    );
    $assert->like(
        $roadmap,
        qr/MB720 Hailo release gate.*?channel brain.*?reply-before-learn.*?provider-neutral.*?language.*?fallback/is,
        'roadmap records the Hailo storage, ordering, provider, language and fallback boundaries',
    );
    $assert->like(
        $roadmap,
        qr/\| MB719 \| P0 \|[^\n]*Root grants/i,
        'database production gate remains ahead of the Hailo work',
    );
    $assert->like(
        $roadmap,
        qr/\| MB726 \| Final \|/,
        'renumbered release decision remains explicit and final',
    );

    $assert->like(
        $design,
        qr/Each IRC channel owns an independent durable Hailo brain/,
        'design requires one durable brain per channel',
    );
    $assert->like(
        $design,
        qr/reply is generated.*before.*triggering line.*learned/is,
        'design requires reply-before-learn ordering',
    );
    $assert->like(
        $design,
        qr/provider-neutral.*constrained post-edit/is,
        'design requires provider-neutral post-editing',
    );
    $assert->like(
        $design,
        qr/configured channel language.*triggering\s+phrase language.*Hailo draft language/is,
        'design accounts for channel, trigger and draft languages',
    );
    $assert->like(
        $design,
        qr/falls\s+back to the original sanitized Hailo candidate/i,
        'design fails open to the learned Hailo candidate, not a generic answer',
    );

};
