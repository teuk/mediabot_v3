# t/cases/13_partyline_eval_safety.t
# =============================================================================
# Regression checks for Partyline eval safety.
#
# The official sample config lives at the repository root only.
# This test intentionally avoids naming any obsolete duplicate sample location.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Find;
use File::Spec;

sub _slurp {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _find_sample_configs {
    my @files;

    find(
        {
            no_chdir => 1,
            wanted   => sub {
                return unless -f $File::Find::name;
                return unless $File::Find::name =~ /(?:^|\/)mediabot\.sample\.conf\z/;
                push @files, $File::Find::name;
            },
        },
        '.'
    );

    return sort @files;
}

return sub {
    my ($assert) = @_;

    my $partyline   = _slurp(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));
    my $root_sample = File::Spec->catfile('.', 'mediabot.sample.conf');
    my $sample_conf = _slurp($root_sample);

    my @samples = _find_sample_configs();

    $assert->is(
        join(', ', @samples),
        './mediabot.sample.conf',
        'only the root sample config exists'
    );

    $assert->ok(
        $partyline =~ /PARTYLINE_EVAL_ENABLED/,
        'Partyline.pm references PARTYLINE_EVAL_ENABLED safety guard'
    );

    $assert->ok(
        $partyline =~ /PARTYLINE_EVAL_TIMEOUT_SECONDS/,
        'Partyline.pm references PARTYLINE_EVAL_TIMEOUT_SECONDS'
    );

    $assert->ok(
        $partyline =~ /alarm\(/,
        'Partyline eval code uses alarm timeout protection'
    );

    $assert->ok(
        $sample_conf =~ /PARTYLINE_EVAL_ENABLED=0/,
        'root sample config disables partyline eval by default'
    );

    $assert->ok(
        $sample_conf =~ /PARTYLINE_EVAL_TIMEOUT_SECONDS=5/,
        'root sample config documents PARTYLINE_EVAL_TIMEOUT_SECONDS'
    );
};
