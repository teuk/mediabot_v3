# t/cases/625_mb407_channels_canonical_lc_key.t
# =============================================================================
# mb407 — Le hash {channels} a une clé CANONIQUE lc, et tous les lookups par
# nom variable passent par lc().
#
# Avant, deux conventions coexistaient : populateChannels indexait par le nom
# EXACT de la DB ("#Teuk"), tandis que l'ajout live (chanadd) indexait par
# lc("#teuk"). Le même canal changeait donc de clé selon qu'il avait été
# ajouté avant ou après le dernier restart, et un lookup avec la casse tapée
# par l'utilisateur ("m chanset #TeuK …") pouvait rater l'objet (chansets,
# ids, antiflood). IRC est insensible à la casse : la clé doit l'être aussi.
# mb407 : populateChannels indexe en lc, et TOUS les lookups {channels}{$var}
# sont wrappés lc (no-op pour les clés déjà canoniques issues de keys).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_625 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    # --- 1. populateChannels indexe en lc ----------------------------------
    my $med = _slurp_625(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));
    (my $med_code = $med) =~ s/^\s*#.*$//mg;
    $assert->like($med_code, qr/\{channels\}\{ lc\(\$ref->\{name\}\) \} = \$channel_obj;/,
        'populateChannels indexe par lc(name)');
    $assert->unlike($med_code, qr/\{channels\}\{ \$ref->\{name\} \}/,
        'plus d\'indexation par le nom exact DB');

    # --- 2. Aucun lookup par variable sans lc dans tout l'arbre ------------
    my @offenders;
    for my $f (glob('Mediabot/*.pm'), glob('Mediabot/*/*.pm'), 'mediabot.pl') {
        my $s = eval { _slurp_625($f) } // next;
        $s =~ s/^\s*#.*$//mg;
        while ($s =~ /(\{channels\}\{\$[a-zA-Z_]+\})/g) {
            push @offenders, "$f: $1";
        }
    }
    $assert->is(join('; ', @offenders), '',
        'tous les lookups {channels}{$var} sont wrappés lc');

    # --- 3. Écriture live (chanadd) et delete cohérents --------------------
    my $cc = _slurp_625(File::Spec->catfile('.', 'Mediabot', 'ChannelCommands.pm'));
    (my $cc_code = $cc) =~ s/^\s*#.*$//mg;
    $assert->like($cc_code, qr/\{channels\}\{lc\(\$sChannel\)\} = \$channel;/,
        'chanadd indexe en lc (inchangé)');
    my $ndel = () = $cc_code =~ /delete \$self->\{channels\}\{lc/g;
    $assert->is($ndel, 1, 'un seul delete lc (doublon nettoyé)');

    # --- 4. Sémantique : la clé lc unifie les deux chemins ------------------
    my %channels;
    $channels{ lc('#Teuk') } = 'from-db';       # populate (DB "#Teuk")
    $assert->is($channels{ lc('#teuk') }, 'from-db', 'lookup casse utilisateur -> trouvé');
    $assert->is($channels{ lc('#TEUK') }, 'from-db', 'lookup MAJUSCULES -> trouvé');
    $assert->is(scalar(keys %channels), 1, 'une seule clé pour un canal (pas de doublon)');

    $assert->like($med, qr/mb407-B1/, 'tag mb407-B1');
};
