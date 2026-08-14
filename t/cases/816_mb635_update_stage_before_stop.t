# t/cases/816_mb635_update_stage_before_stop.t
# =============================================================================
# mb635 — la partie lente/faillible de l'update se fait AVANT le SIGTERM.
# =============================================================================
use strict;
use warnings;
use utf8;

return sub {
    my ($assert) = @_;

    open my $fh, '<:encoding(UTF-8)', 'install/deploy_update.sh' or die $!;
    local $/;
    my $sh = <$fh>;
    close $fh;

    my $clone   = index($sh, 'git clone https://github.com/teuk/mediabot_v3');
    my $syntax  = index($sh, 'Checking Perl syntax in the staged release');
    my $integ   = index($sh, 'startup_integrity_check.pl --manifest');
    my $stop    = index($sh, 'Sending SIGTERM to PID');
    my $restore = index($sh, 'Restoring config and Hailo brain into the staged release');
    my $rotate  = index($sh, 'Archiving current release:');
    my $active  = index($sh, 'Activating new release:');

    for my $pair (
        [ clone   => $clone   ],
        [ syntax  => $syntax  ],
        [ integ   => $integ   ],
        [ stop    => $stop    ],
        [ restore => $restore ],
        [ rotate  => $rotate  ],
        [ active  => $active  ],
    ) {
        $assert->ok($pair->[1] >= 0, "mb635-816: etape '$pair->[0]' trouvee");
    }

    $assert->ok($clone < $syntax,
        'mb635-816: clone avant validation syntaxique');
    $assert->ok($syntax < $integ,
        'mb635-816: syntaxe avant integrity check');
    $assert->ok($integ < $stop,
        'mb635-816: candidat entierement valide AVANT SIGTERM');
    $assert->ok($stop < $restore,
        'mb635-816: etat prive copie apres arret du bot');
    $assert->ok($restore < $rotate,
        'mb635-816: conf/cerveau restaures avant rotation');
    $assert->ok($rotate < $active,
        'mb635-816: archive ancien arbre puis active le nouveau');

    $assert->like($sh, qr/clone \+ staged validation happen BEFORE this stop/,
        'mb635-816: raison de l ordre documentee dans le script');
    $assert->like($sh, qr/cp -pfv "\$\{PROJECT_DIR\}\/mediabot\.conf" "\$\{TMP_CLONE_DIR\}\/"/,
        'mb635-816: mediabot.conf preservee');
    $assert->like($sh, qr/LATEST_BRAIN/,
        'mb635-816: cerveau Hailo preserve');
};
