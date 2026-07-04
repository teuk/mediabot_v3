# t/cases/615_mb397_sample_conf_key_coverage.t
# =============================================================================
# mb397 — Toute clé de config LUE par le code doit exister dans
# mediabot.sample.conf (active ou commentée avec son défaut).
#
# Objectif 3.3 : « configure donne toutes les keys par défaut ». Or 4 clés
# étaient lues par le code sans apparaître dans le sample (donc invisibles pour
# une installation fraîche et pour le wizard configure) :
#   anthropic.TEMPERATURE, main.ACHIEVEMENTS_PATH, main.BOT_NICKS, radio.ENABLED
# mb397 les documente (commentées = défauts du code, comportement inchangé) et
# CE TEST verrouille la couverture : toute nouvelle clé littérale lue via
# get('section.KEY') / get_int('section.KEY') sans entrée dans le sample fera
# échouer la suite.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_615 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    # --- 1. Collecter les clés littérales lues par le code ----------------
    my %code_keys;
    my @files;
    for my $dir ('Mediabot', File::Spec->catdir('Mediabot','External'),
                 File::Spec->catdir('Mediabot','Radio')) {
        opendir(my $dh, $dir) or next;
        push @files, map { File::Spec->catfile($dir, $_) }
                     grep { /\.pm\z/ } readdir($dh);
        closedir $dh;
    }
    push @files, 'mediabot.pl';

    for my $f (@files) {
        my $src = eval { _slurp_615($f) } // next;
        # retirer les lignes de commentaire pour éviter les faux positifs
        $src =~ s/^\s*#.*$//mg;
        while ($src =~ /get(?:_int)?\(\s*'([a-z_]+\.[A-Z_0-9]+)'/g) {
            $code_keys{$1} = 1;
        }
    }
    $assert->ok(scalar(keys %code_keys) >= 50,
        'au moins 50 clés littérales détectées dans le code (sanity)');

    # --- 2. Collecter les clés du sample (actives OU commentées) ----------
    my %sample_keys;
    my $section = '';
    for my $line (split /\n/, _slurp_615('mediabot.sample.conf')) {
        if ($line =~ /^\[([a-z_]+)\]/) { $section = $1; next; }
        if ($line =~ /^#?([A-Z_0-9]+)=/) {
            $sample_keys{"$section.$1"} = 1 if $section ne '';
        }
    }
    $assert->ok(scalar(keys %sample_keys) >= 100,
        'au moins 100 clés dans le sample (sanity)');

    # --- 3. Couverture : code ⊆ sample -----------------------------------
    my @missing = sort grep { !$sample_keys{$_} } keys %code_keys;
    $assert->is(join(', ', @missing), '',
        'toutes les clés lues par le code existent dans mediabot.sample.conf');

    # --- 4. Les 4 clés mb397 sont bien documentées ------------------------
    for my $k (qw(anthropic.TEMPERATURE main.ACHIEVEMENTS_PATH
                  main.BOT_NICKS radio.ENABLED)) {
        $assert->ok($sample_keys{$k}, "clé $k documentée dans le sample (mb397)");
    }
    $assert->like(_slurp_615('mediabot.sample.conf'), qr/mb397-R1/, 'tag mb397-R1');
};
