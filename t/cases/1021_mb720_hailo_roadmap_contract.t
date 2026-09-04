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
        qr/\| MB720 \| Complete on development pilot \|[^\n]*Hailo[^\n]*per-channel[^\n]*post-editor/i,
        'MB720 records the completed development engineering gate',
    );
    $assert->like(
        $roadmap,
        qr/MB720 Hailo engineering gate[^\n]*complete on development.*?MB722 now owns the remaining Hailo release evidence/is,
        'roadmap separates completed Hailo engineering from rollout evidence',
    );
    $assert->like(
        $roadmap,
        qr/MB720 Hailo engineering gate.*?channel brain.*?reply-before-learn.*?provider-neutral.*?language.*?fallback/is,
        'roadmap records the Hailo storage, ordering, provider, language and fallback boundaries',
    );
    $assert->like(
        $roadmap,
        qr/\| MB719 \| P0 \|[^\n]*Root grants/i,
        'database production gate remains on the critical release path',
    );
    $assert->like(
        $roadmap,
        qr/\| MB727 \| Final \|/,
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
    $assert->like(
        $design,
        qr/MB720 development gate is complete.*?Cross-instance rollout and\s+observation are tracked by MB722/is,
        'Hailo design and roadmap agree on the remaining promotion boundary',
    );

};
