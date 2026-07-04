# t/cases/621_mb403_init_no_metrics_before_creation.t
# =============================================================================
# mb403 — Le bloc d'init de mediabot.pl n'utilise plus {metrics} avant la
# création de l'objet Metrics.
#
# Deux blocs "if ($mediabot->{metrics}) { ->set(...) }" vivaient AVANT
# `$mediabot->{metrics} = Mediabot::Metrics->new(...)` : à ce stade {metrics}
# est toujours undef, donc ils étaient MORTS et laissaient croire que les
# gauges (db_connected, channels_managed) étaient posées dès la connexion DB.
# Les gauges initiales sont réellement posées dans le bloc unique qui suit
# start_http_server(). Ce test verrouille l'ordre : dans la section MAIN,
# aucun usage de {metrics} ne précède sa création.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_621 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    my $src = _slurp_621('mediabot.pl');

    # Isoler la section MAIN (après la bannière) jusqu'à $loop->run.
    my ($main) = $src =~ /(# !\s+MAIN\s+!.*?\$loop->run;)/s;
    $assert->ok(defined $main && $main ne '', 'section MAIN isolée');

    (my $code = $main) =~ s/^\s*#.*$//mg;   # ignorer les commentaires

    my $creation_pos = index($code, '{metrics} = Mediabot::Metrics->new');
    $assert->ok($creation_pos > 0, 'création de Metrics trouvée dans MAIN');

    my $before = substr($code, 0, $creation_pos);
    my @uses = $before =~ /(\{metrics\}->)/g;
    $assert->is(scalar(@uses), 0,
        'aucun usage de {metrics}-> avant sa création dans le bloc d\'init');

    # Les gauges initiales existent bien après start_http_server.
    my $after = substr($code, $creation_pos);
    $assert->like($after, qr/start_http_server\(\).*?mediabot_db_connected/s,
        'gauge db_connected posée après le démarrage du serveur metrics');
    $assert->like($after, qr/start_http_server\(\).*?mediabot_channels_managed/s,
        'gauge channels_managed posée après le démarrage du serveur metrics');

    $assert->like($src, qr/mb403-R1/, 'tag mb403-R1');
};
