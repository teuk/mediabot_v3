# t/cases/185_openai_admin_models_command.t
# =============================================================================
# Regression checks for the Owner-only "openai models" command.
#
# The command lists models visible to the configured API key, with an optional
# filter, without exposing the API key.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_185 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_185 {
    my ($src, $sub_name) = @_;

    my $start_re = qr/^sub\s+\Q$sub_name\E\s*\{/m;
    return undef unless $src =~ /$start_re/g;

    my $start = pos($src);
    my $depth = 1;
    my $pos   = $start;
    my $len   = length($src);

    while ($pos < $len) {
        my $char = substr($src, $pos, 1);

        if ($char eq '{') {
            $depth++;
        }
        elsif ($char eq '}') {
            $depth--;

            if ($depth == 0) {
                return substr($src, $start, $pos - $start);
            }
        }

        $pos++;
    }

    return undef;
}

return sub {
    my ($assert) = @_;

    my $admin  = _slurp_185(File::Spec->catfile('.', 'Mediabot', 'AdminCommands.pm'));
    my $sample = _slurp_185('mediabot.sample.conf');

    my $url_body    = _extract_sub_body_185($admin, '_openai_models_url');
    my $models_body = _extract_sub_body_185($admin, '_openai_notice_models');
    my $openai_body = _extract_sub_body_185($admin, 'openai_ctx');

    $assert->ok(defined $url_body,    '_openai_models_url body found');
    $assert->ok(defined $models_body, '_openai_notice_models body found');
    $assert->ok(defined $openai_body, 'openai_ctx body found');

    $assert->like(
        $url_body // '',
        qr{/chat/completions\\z\}\{/models\}},
        '_openai_models_url derives /models from /chat/completions'
    );

    $assert->like(
        $models_body // '',
        qr/openai\.API_KEY/,
        'openai models reads API key internally'
    );

    $assert->like(
        $models_body // '',
        qr/OpenAI models: API key is missing\./,
        'openai models reports missing API key safely'
    );

    $assert->like(
        $models_body // '',
        qr/Authorization' => "Bearer \$api_key"/,
        'openai models authenticates with API key'
    );

    $assert->like(
        $models_body // '',
        qr/ref\(\$data->\{data\}\) eq 'ARRAY'/,
        'openai models validates response shape'
    );

    $assert->like(
        $models_body // '',
        qr/lc\(\$id\) !~ /,
        'openai models supports filtering'
    );

    $assert->like(
        $models_body // '',
        qr/my \$limit = 12;/,
        'openai models limits IRC output'
    );

    $assert->unlike(
        $models_body // '',
        qr/botNotice\([^;]*\$api_key/s,
        'openai models never prints the API key'
    );

    $assert->like(
        $openai_body // '',
        qr/if \(\$subcmd eq 'models' \|\| \$subcmd eq 'model_list'\)/,
        'openai_ctx supports models command'
    );

    $assert->like(
        $openai_body // '',
        qr/_openai_notice_models\(\$self, \$nick, \@args\);/,
        'openai_ctx dispatches to _openai_notice_models'
    );

    $assert->like(
        $admin,
        qr/openai models \[filter\]/,
        'openai help documents models command'
    );

    $assert->like(
        $sample,
        qr/openai models gpt-5/,
        'sample config documents filtering model list'
    );
};
