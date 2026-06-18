# t/cases/114_sample_api_keys_empty_defaults.t
# =============================================================================
# Regression checks for API keys in mediabot.sample.conf and their current
# modular runtime readers.
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

    my @runtime_files = (
        File::Spec->catfile('.', 'Mediabot', 'AdminCommands.pm'),
        File::Spec->catfile('.', 'Mediabot', 'External', 'Claude.pm'),
        File::Spec->catfile('.', 'Mediabot', 'External', 'YouTube.pm'),
        File::Spec->catfile('.', 'mediabot.pl'),
    );

    my $runtime = join "\n", map {
        $assert->ok(-f $_, "runtime source exists: $_");
        _slurp_sample_api_keys($_);
    } @runtime_files;

    for my $section (qw(openai fortnite tmdb)) {
        my $body = _section_body_sample_api_keys($sample, $section);
        $assert->ok(defined $body, "sample config has [$section] section");
        $assert->like(
            $body // '',
            qr/^API_KEY=$/m,
            "sample [$section] defines an empty API_KEY by default"
        );
        $assert->unlike(
            $body // '',
            qr/API_KEY=\S+/,
            "sample [$section] contains no active API key"
        );
    }

    $assert->unlike($sample, qr/API_KEY=sk-proj-/, 'sample contains no OpenAI project key');
    $assert->unlike($sample, qr/API_KEY=\*+/, 'sample contains no asterisk API-key placeholder');

    $assert->like($runtime, qr/get\('openai\.API_KEY'\)/, 'runtime reads openai.API_KEY');
    $assert->like($runtime, qr/get\('fortnite\.API_KEY'\)/, 'runtime reads fortnite.API_KEY');
    $assert->like($runtime, qr/get\('tmdb\.API_KEY'\)/, 'runtime reads tmdb.API_KEY');
};
