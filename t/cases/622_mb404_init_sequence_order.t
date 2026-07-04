# t/cases/622_mb404_init_sequence_order.t
# =============================================================================
# mb404 — L'ordre d'initialisation de mediabot.pl est verrouillé.
#
# La séquence du bloc MAIN est ordre-dépendante (DB avant tout usage,
# dbCheckTables avant l'auth, logout avant tout login, canaux avant les
# gauges, loop avant Metrics, login en dernier) mais rien ne l'imposait :
# un réordonnancement accidentel n'aurait été détecté qu'au boot en prod.
# mb404 documente l'ordre en tête de section (commentaire mb404-R1) et CE
# TEST vérifie mécaniquement l'ordre d'apparition des étapes dans MAIN.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

sub _slurp_622 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    my $src = _slurp_622('mediabot.pl');
    my ($main) = $src =~ /(# !\s+MAIN\s+!.*?\$loop->run;)/s;
    $assert->ok(defined $main && $main ne '', 'section MAIN isolée');

    (my $code = $main) =~ s/^\s*#.*$//mg;   # ignorer les commentaires

    # Étapes dans l'ordre requis (motifs uniques dans MAIN).
    my @steps = (
        [ 'DB'               => qr/\{db\} = Mediabot::DB->new/          ],
        [ 'ChannelBan'       => qr/Mediabot::ChannelBan->new/            ],
        [ 'dbCheckTables'    => qr/->dbCheckTables\(\)/                  ],
        [ 'init_auth'        => qr/->init_auth\(\)/                      ],
        [ 'dbLogoutUsers'    => qr/->dbLogoutUsers\(\)/                  ],
        [ 'populateChannels' => qr/->populateChannels\(\)/               ],
        [ 'loop'             => qr/IO::Async::Loop->new/                 ],
        [ 'Metrics'          => qr/\{metrics\} = Mediabot::Metrics->new/ ],
        [ 'metrics HTTP'     => qr/->start_http_server\(\)/              ],
        [ 'Partyline'        => qr/Mediabot::Partyline->new/             ],
        [ 'login'            => qr/_do_login\(\$irc/                     ],
        [ 'run'              => qr/\$loop->run;/                         ],
    );

    my $last_pos  = -1;
    my $last_name = '(début)';
    for my $s (@steps) {
        my ($name, $re) = @$s;
        my $pos = ($code =~ $re) ? $-[0] : -1;
        $assert->ok($pos >= 0, "étape présente : $name");
        $assert->ok($pos > $last_pos, "ordre : $name après $last_name");
        ($last_pos, $last_name) = ($pos, $name) if $pos >= 0;
    }

    # Le mode d'emploi de l'ordre est documenté en tête de section.
    $assert->like($main, qr/mb404-R1/, 'commentaire d\'ordre (mb404-R1) présent');
};
