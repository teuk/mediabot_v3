# t/cases/594_mb375_prometheus_help_escaping.t
# =============================================================================
# mb375 — Le rendu Prometheus échappe le texte des lignes "# HELP".
#
# Les VALEURS de label étaient déjà échappées, mais pas le texte "# HELP".
# Selon la spec d'exposition Prometheus, un help doit échapper l'antislash
# (\ -> \\) et le saut de ligne (\n -> \n). Un help contenant un de ces
# caractères produisait une ligne malformée pouvant casser TOUT le scrape.
# mb375 ajoute _escape_help_text() et l'applique au rendu ("# TYPE" reçoit en
# prime un défaut défensif 'untyped').
#
# Validation : (a) sémantique de l'échappement, (b) scan de source.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

# Reproduction fidèle de _escape_help_text.
sub _esc {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/\\/\\\\/g;
    $s =~ s/\n/\\n/g;
    return $s;
}

sub _slurp_594 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    # --- 1. Sémantique de l'échappement ----------------------------------
    $assert->is(_esc('normal help text'), 'normal help text', 'help normal inchangé');
    $assert->is(_esc('path C:\\dir'),     'path C:\\\\dir',   'antislash échappé');
    $assert->is(_esc("two\nlines"),        'two\\nlines',     'saut de ligne échappé');
    $assert->is(_esc("a\\b\nc"),           'a\\\\b\\nc',      'antislash + saut de ligne');
    $assert->is(_esc(undef),               '',                'undef -> chaîne vide (pas de warning)');
    # ordre correct : l'antislash est échappé AVANT le \n (sinon double échappement).
    $assert->is(_esc("x\ny"),              'x\\ny',           'ordre antislash-puis-LF correct');

    # --- 2. Scan de source -----------------------------------------------
    my $src = _slurp_594(File::Spec->catfile('.', 'Mediabot', 'Metrics.pm'));
    $assert->like($src, qr/sub _escape_help_text/, 'helper _escape_help_text défini');
    # le rendu applique l'échappement au HELP.
    $assert->like($src, qr/# HELP %s %s".*_escape_help_text\(\$m->\{help\}\)/,
                  'la ligne # HELP échappe le texte');
    # antislash échappé avant le saut de ligne dans le helper.
    my ($helper) = $src =~ /(sub _escape_help_text \{.*?\n\}\n)/s; $helper //= '';
    $assert->like($helper, qr/s\/\\\\\/\\\\\\\\\/g.*s\/\\n\/\\\\n\/g/s,
                  'helper: antislash échappé avant le \n');
    # défaut défensif sur le TYPE.
    $assert->like($src, qr/'untyped'/, '# TYPE a un défaut défensif');
    $assert->like($src, qr/mb375-R1/, 'tag mb375-R1 présent');
};
