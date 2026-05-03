# t/cases/43_responder_exact_match.t
# =============================================================================
# Static regression checks for exact responder matching.
#
# Responders are command-like keys. They should not use SQL LIKE, because
# responder text containing '%' or '_' would otherwise match unintended rows.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_responder_exact_match {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_responder_exact_match(File::Spec->catfile('.', 'Mediabot', 'DBCommands.pm'));

    $assert->ok(
        $src =~ /RESPONDERS\.responder = \?/,
        'runtime responder lookup uses exact responder match'
    );

    $assert->ok(
        $src =~ /CHANNEL\.name = \?/,
        'runtime responder channel lookup uses exact channel match'
    );

    $assert->ok(
        $src =~ /SELECT answer, chance, hits FROM RESPONDERS WHERE id_channel = \? AND responder = \?/,
        'addresponder duplicate check uses exact responder match'
    );

    $assert->ok(
        $src =~ /SELECT responder, answer, chance, hits\s+FROM RESPONDERS\s+WHERE id_channel = \? AND responder = \?/s,
        'delresponder SELECT uses exact responder match'
    );

    $assert->ok(
        $src =~ /DELETE FROM RESPONDERS\s+WHERE id_channel = \? AND responder = \?/s,
        'delresponder DELETE uses exact responder match'
    );

    $assert->ok(
        $src !~ /RESPONDERS\.responder LIKE \?/,
        'DBCommands no longer uses RESPONDERS.responder LIKE'
    );

    $assert->ok(
        $src !~ /responder LIKE \?/,
        'DBCommands no longer uses responder LIKE direct lookup'
    );

    $assert->ok(
        $src !~ /CHANNEL\.name LIKE \? AND CHANNEL\.id_channel IS NOT NULL\) OR RESPONDERS\.id_channel = 0\) AND RESPONDERS\.responder/,
        'runtime responder lookup no longer uses CHANNEL.name LIKE'
    );
};
