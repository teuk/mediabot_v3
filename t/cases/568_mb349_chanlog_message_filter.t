# t/cases/568_mb349_chanlog_message_filter.t
# =============================================================================
# mb349 — .logs (_cmd_chanlog) n'affiche que les vrais messages.
#
# mb348 avait laissé le viewer .logs sur `publictext IS NOT NULL` (viewer brut).
# À la demande, mb349 le filtre comme le reste : .logs affiche un log de
# CONVERSATION au format `[ts] <nick> texte`, donc montrer join/part/kick/mode/
# topic (ex. `<bob> +o alice`) était trompeur — on filtre désormais
# `event_type IN ('public','action')`.
#
# Avec mb349, plus AUCUNE occurrence SQL de `publictext IS NOT NULL` ne subsiste
# dans tout l'arbre (balayage 100 % terminé).
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_568 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _strip_comments_568 {
    my ($s) = @_;
    $s =~ s/^\s*#.*$//mg;
    return $s;
}

return sub {
    my ($assert) = @_;

    my $pl = _slurp_568(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));

    # _cmd_chanlog filtré
    my ($logs) = $pl =~ /(sub _cmd_chanlog \{.*?\n\}\n)/s; $logs //= '';
    $assert->ok($logs ne '', 'sub _cmd_chanlog extraite');
    my $logs_sql = _strip_comments_568($logs);
    $assert->like($logs_sql, qr/event_type IN \('public','action'\)/,
                  '.logs filtre event_type IN (public,action)');
    $assert->unlike($logs_sql, qr/publictext IS NOT NULL/,
                  '.logs : plus de publictext IS NOT NULL en SQL');
    $assert->like($logs, qr/mb349-B1/, 'tag mb349-B1 présent');

    # Balayage 100 % : plus aucune occurrence SQL dans tout l'arbre Mediabot.
    my @files;
    my $dir = File::Spec->catdir('.', 'Mediabot');
    my $wanted; $wanted = sub {
        my ($d) = @_;
        opendir(my $dh, $d) or return;
        for my $e (sort readdir $dh) {
            next if $e eq '.' || $e eq '..';
            my $p = File::Spec->catfile($d, $e);
            if (-d $p) { $wanted->($p); }
            elsif ($e =~ /\.pm$/) { push @files, $p; }
        }
        closedir $dh;
    };
    $wanted->($dir);

    my $total = 0;
    for my $f (@files) {
        my $src = _slurp_568($f);
        $src = _strip_comments_568($src);
        my $n = () = $src =~ /publictext IS NOT NULL/g;
        $total += $n;
    }
    $assert->is($total, 0,
        'plus AUCUN publictext IS NOT NULL en SQL dans tout Mediabot/ (balayage complet)');
};
