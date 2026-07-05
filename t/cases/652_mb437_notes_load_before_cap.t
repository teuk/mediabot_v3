# t/cases/652_mb437_notes_load_before_cap.t
# =============================================================================
# mb437 — Le plafond de 10 notes est évalué contre les notes réelles (DB
# comprise), pas seulement le cache mémoire.
#
# mbNote_ctx (ajout) ne chargeait jamais les notes depuis la DB — seul
# mbNotes_ctx (liste) le faisait. Après un restart, le cache mémoire est vide :
# le premier !note voyait 0 note et laissait dépasser 10 en base ; les notes
# au-delà de 10 devenaient invisibles (SELECT ... LIMIT 10). mb437 : helper
# partagé _notes_ensure_loaded appelé côté ajout ET liste.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_652 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    # --- 1. Sémantique : plafond respecté après un restart -----------------
    my %notes;                                   # cache vide (restart)
    my @db = map { { id => $_, text => "note$_" } } 1 .. 10;   # 10 notes en DB
    my $ensure = sub {
        my ($k) = @_;
        return if @{ $notes{$k} // [] };
        $notes{$k} = [ @db ];                    # simule le SELECT ... LIMIT 10
    };

    # Ancien comportement (sans load) : ajout autorisé à tort.
    my $old_allowed = !@{ $notes{'teuk'} // [] };
    $assert->is($old_allowed, 1, 'ancien: cache vide laisserait ajouter (bug)');

    # Nouveau : on charge d'abord, le plafond est atteint.
    $ensure->('teuk');
    my $blocked = scalar(@{ $notes{'teuk'} }) >= 10 ? 1 : 0;
    $assert->is($blocked, 1, 'nouveau: plafond de 10 atteint après chargement DB');
    $assert->is(scalar @{ $notes{'teuk'} }, 10, '10 notes chargées');

    # Idempotence : un second ensure ne double pas.
    $ensure->('teuk');
    $assert->is(scalar @{ $notes{'teuk'} }, 10, 'ensure idempotent (pas de doublon)');

    # --- 2. Câblage réel ---------------------------------------------------
    my $src = _slurp_652(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));

    $assert->like($src, qr/sub _notes_ensure_loaded \{/, 'helper _notes_ensure_loaded défini');

    my ($add) = $src =~ /(sub mbNote_ctx \{.*?\n\}\n)/s; $add //= '';
    (my $acode = $add) =~ s/^\s*#.*$//mg;
    $assert->like($acode, qr/_notes_ensure_loaded\(\$self, \$nick\);/, 'ajout charge la DB avant le plafond');
    $assert->like($acode, qr/_notes_ensure_loaded.*?>= 10/s, 'chargement AVANT le test de plafond');

    my ($list) = $src =~ /(sub mbNotes_ctx \{.*?\n\}\n)/s; $list //= '';
    (my $lcode = $list) =~ s/^\s*#.*$//mg;
    $assert->like($lcode, qr/_notes_ensure_loaded\(\$self, \$nick\);/, 'liste utilise le helper partagé');
    $assert->unlike($lcode, qr/SELECT id_note, text FROM NOTE/, 'plus de SELECT inline dupliqué dans la liste');

    $assert->like($src, qr/mb437-B1/, 'tag mb437-B1');
};
