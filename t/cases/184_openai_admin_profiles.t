# t/cases/184_openai_admin_profiles.t
# =============================================================================
# Regression checks for Owner-only OpenAI/tellme profiles.
#
# Profiles let an Owner apply a coherent group of runtime values at once:
# dev, compact, safe, default.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_184 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_184 {
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

    my $admin  = _slurp_184(File::Spec->catfile('.', 'Mediabot', 'AdminCommands.pm'));
    my $sample = _slurp_184('mediabot.sample.conf');

    my $spec_body   = _extract_sub_body_184($admin, '_openai_profile_spec');
    my $apply_body  = _extract_sub_body_184($admin, '_openai_apply_profile');
    my $openai_body = _extract_sub_body_184($admin, 'openai_ctx');

    $assert->ok(defined $spec_body,   '_openai_profile_spec body found');
    $assert->ok(defined $apply_body,  '_openai_apply_profile body found');
    $assert->ok(defined $openai_body, 'openai_ctx body found');

    for my $profile (qw(dev compact safe default)) {
        $assert->like(
            $spec_body // '',
            qr/\Q$profile\E\s+=> \{/,
            "profile $profile exists"
        );
    }

    for my $param (qw(model temperature max_tokens max_privmsg wrap_bytes sleep_us)) {
        $assert->like(
            $apply_body // '',
            qr/\Q$param\E/,
            "profile apply handles $param"
        );
    }

    $assert->like(
        $apply_body // '',
        qr/\$self->\{conf\}->set\(\$spec->\{key\}, \$clean_or_error\);/,
        'profile apply persists values through Conf->set'
    );

    $assert->like(
        $apply_body // '',
        qr/\$self->\{conf\}->save\(\);/,
        'profile apply saves configuration'
    );

    $assert->like(
        $openai_body // '',
        qr/if \(\$subcmd eq 'profiles'\)/,
        'openai_ctx supports profiles listing'
    );

    $assert->like(
        $openai_body // '',
        qr/if \(\$subcmd eq 'profile' \|\| \$subcmd eq 'preset'\)/,
        'openai_ctx supports profile/preset apply'
    );

    $assert->like(
        $admin,
        qr/openai profile <dev\|compact\|safe\|default>/,
        'openai help documents profile usage'
    );

    $assert->like(
        $sample,
        qr/openai profile dev/,
        'sample documents dev profile'
    );

    $assert->like(
        $sample,
        qr/openai profile compact/,
        'sample documents compact profile'
    );

    $assert->like(
        $sample,
        qr/openai profile safe/,
        'sample documents safe profile'
    );

    $assert->like(
        $sample,
        qr/OpenAI profile summary/,
        'sample contains profile summary'
    );
};
