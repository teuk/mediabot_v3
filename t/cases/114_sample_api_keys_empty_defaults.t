# t/cases/114_sample_api_keys_empty_defaults.t
# =============================================================================
# Regression checks for API keys in mediabot.sample.conf.
#
# Sample configs should not contain active fake API keys. Empty values are safer:
# users explicitly fill them when they want the feature enabled.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_sample_api_keys {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _section_body_sample_api_keys {
    my ($src, $section) = @_;

    my ($body) = $src =~ /^\[\Q$section\E\]\s*\n(.*?)(?=^\[[^\]]+\]\s*$|\z)/ms;
    return $body;
}

return sub {
    my ($assert) = @_;

    my $sample = _slurp_sample_api_keys(
        File::Spec->catfile('.', 'mediabot.sample.conf')
    );

    my $runtime = _slurp_sample_api_keys(
        File::Spec->catfile('.', 'Mediabot', 'External.pm')
    ) . "\n" . _slurp_sample_api_keys(
        File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm')
    ) . "\n" . _slurp_sample_api_keys(
        File::Spec->catfile('.', 'mediabot.pl')
    );

    for my $section (qw(openai fortnite tmdb)) {
        my $body = _section_body_sample_api_keys($sample, $section);

        $assert->ok(
            defined $body,
            "sample config has [$section] section"
        );

        $assert->like(
            $body // '',
            qr/^API_KEY=$/m,
            "sample [$section] defines an empty API_KEY by default"
        );

        $assert->unlike(
            $body // '',
            qr/API_KEY=\S+/,
            "sample [$section] does not contain an active fake API key"
        );
    }

    $assert->unlike(
        $sample,
        qr/API_KEY=sk-proj-/,
        'sample config does not contain a fake OpenAI project key'
    );

    $assert->unlike(
        $sample,
        qr/API_KEY=\*+/,
        'sample config does not contain asterisk API key placeholders'
    );

    $assert->like(
        $runtime,
        qr/get\('openai\.API_KEY'\)/,
        'runtime reads openai.API_KEY'
    );

    $assert->like(
        $runtime,
        qr/get\('fortnite\.API_KEY'\)/,
        'runtime reads fortnite.API_KEY'
    );

    $assert->like(
        $runtime,
        qr/get\('tmdb\.API_KEY'\)/,
        'runtime reads tmdb.API_KEY'
    );
};
