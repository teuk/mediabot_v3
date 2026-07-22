# t/cases/740_mb543_network_metrics_overview.t
# =============================================================================
# mb543 — stats réseau LUSERS + dashboard overview « look 3.3 » (demande
# explicite : la bannière du README montrait un dashboard qui n'existait
# pas — fin de la pub mensongère).
#
# Contrats :
#   [1] parsing coeur update_network_metrics_from_numeric : 251 (users
#       visibles+invisibles, serveurs), 252 (ops), 254 (channels), 266
#       (global current/max en args OU en texte), garbage inoffensif,
#       266 prioritaire sur 251 pour les users ;
#   [2] maybe_request_lusers : off (0), throttle par intervalle, envoi réel
#       via l'irc, bornes 60..3600, non connecté = silence ;
#   [3] gardes statiques mediabot.pl : cinq handlers 251/252/254/265/266
#       déclarés + câblés dans la table + tick périodique branché ;
#   [4] Metrics.pm déclare les cinq gauges mediabot_network_* ;
#   [5] dashboard overview : JSON valide, variables bot/channel, rangée de
#       stats COMPACTE (h=3 — l'exigence du round), logos cliquables vers
#       grafana.com et prometheus.io, et doc-truth : chaque série mediabot_*
#       référencée existe dans Metrics.pm ou dans les declare du plugin ;
#   [6] READMEs et sample.conf documentés.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use JSON::PP ();

sub _slurp_740 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

{ package L740; sub new { bless {}, shift } sub log { 1 } }

{
    package Metrics740;
    sub new { bless { sets => {} }, shift }
    sub can { 1 }
    sub set { my ($self, $name, $v) = @_; $self->{sets}{$name} = $v; 1 }
}

{
    package IRC740;
    sub new { bless { connected => 1, sent => [] }, shift }
    sub is_connected { $_[0]->{connected} }
    sub send_message {
        my ($self, @args) = @_;
        die "simulated LUSERS send failure\n" if $self->{fail};
        push @{ $self->{sent} }, \@args;
        1;
    }
}

{
    package Conf740;
    sub new { my ($class, %kv) = @_; bless { %kv }, $class }
    sub get { $_[0]->{ $_[1] } }
}

return sub {
    my ($assert) = @_;

    my $core_ok = eval { require Mediabot::Mediabot; 1 };

    # ------------------------------------------------------------------
    # [1] Parsing des numerics
    # ------------------------------------------------------------------
    if (!$core_ok) {
        $assert->ok(1, 'SKIP parsing: Mediabot::Mediabot non chargeable ici');
    }
    else {
        my $m = Metrics740->new;
        my $core = bless { metrics => $m, logger => L740->new }, 'Mediabot';

        my $u251 = $core->update_network_metrics_from_numeric('251', [],
            'There are 7 users and 3 invisible on 2 servers');
        $assert->ok($u251->{mediabot_network_users} == 10
            && $u251->{mediabot_network_servers} == 2
            && $m->{sets}{mediabot_network_users} == 10,
            '251: users=visibles+invisibles, serveurs extraits');

        my $u252 = $core->update_network_metrics_from_numeric('252', [ '4' ], 'operator(s) online');
        $assert->ok($u252->{mediabot_network_operators} == 4, '252: operateurs');

        my $u254 = $core->update_network_metrics_from_numeric('254', [ '128' ], 'channels formed');
        $assert->ok($u254->{mediabot_network_channels} == 128, '254: canaux');

        my $u266a = $core->update_network_metrics_from_numeric('266', [ '812', '1024' ], 'Current global users');
        $assert->ok($u266a->{mediabot_network_users} == 812
            && $u266a->{mediabot_network_users_max} == 1024,
            '266: current/max via args');
        $assert->ok($m->{sets}{mediabot_network_users} == 812,
            '266 prioritaire: ecrase la valeur 251');

        my $u266b = $core->update_network_metrics_from_numeric('266', [],
            'Current global users: 900, Max: 1500');
        $assert->ok($u266b->{mediabot_network_users} == 900
            && $u266b->{mediabot_network_users_max} == 1500,
            '266: current/max via texte');

        my $junk = $core->update_network_metrics_from_numeric('251', [ 'x' ], 'nothing useful');
        $assert->ok(ref($junk) eq 'HASH' && !%$junk, 'garbage: rien mis a jour, pas de crash');
        my $unknown = $core->update_network_metrics_from_numeric('999', [], 'whatever');
        $assert->ok(ref($unknown) eq 'HASH' && !%$unknown, 'numeric inconnu: no-op');
    }

    # ------------------------------------------------------------------
    # [2] maybe_request_lusers
    # ------------------------------------------------------------------
    if (!$core_ok) {
        $assert->ok(1, 'SKIP lusers: coeur non chargeable');
    }
    else {
        my $irc = IRC740->new;
        my $core = bless {
            irc => $irc, logger => L740->new,
            conf => Conf740->new('main.LUSERS_REFRESH' => '60'),
        }, 'Mediabot';

        $assert->ok($core->maybe_request_lusers == 1
            && @{ $irc->{sent} } == 1 && $irc->{sent}[0][0] eq 'LUSERS',
            'refresh: LUSERS envoye');
        $assert->ok($core->maybe_request_lusers == 0 && @{ $irc->{sent} } == 1,
            'throttle: pas de second envoi dans la fenetre');

        $core->{network_lusers_last_request} = time() - 61;
        $assert->ok($core->maybe_request_lusers == 1 && @{ $irc->{sent} } == 2,
            'throttle: renvoi apres la fenetre');

        my $off = bless { irc => IRC740->new, logger => L740->new,
            conf => Conf740->new('main.LUSERS_REFRESH' => '0') }, 'Mediabot';
        $assert->ok($off->maybe_request_lusers == 0, 'LUSERS_REFRESH=0: desactive');

        my $dc = bless { irc => IRC740->new, logger => L740->new,
            conf => Conf740->new('main.LUSERS_REFRESH' => '300') }, 'Mediabot';
        $dc->{irc}{connected} = 0;
        $assert->ok($dc->maybe_request_lusers == 0, 'non connecte: silence');

        my $failed = bless { irc => IRC740->new, logger => L740->new,
            conf => Conf740->new('main.LUSERS_REFRESH' => '60'),
            network_lusers_last_request => 123 }, 'Mediabot';
        $failed->{irc}{fail} = 1;
        $assert->ok($failed->maybe_request_lusers == 0
            && $failed->{network_lusers_last_request} == 123,
            'echec envoi periodique: throttle non avance');
    }

    # ------------------------------------------------------------------
    # [3] Gardes statiques mediabot.pl
    # ------------------------------------------------------------------
    {
        my $src = _slurp_740('mediabot.pl');
        for my $n (qw(251 252 254 265 266)) {
            $assert->like($src, qr/on_message_$n\s+=> \\&on_message_$n,/,
                "dispatch: on_message_$n cable");
        }
        $assert->like($src, qr/eval \{ \$mediabot->maybe_request_lusers\(\); \};/,
            'tick: refresh periodique branche sous eval');
        $assert->like($src, qr/update_network_metrics_from_numeric/,
            'handlers: parsing delegue au coeur');
    }

    # ------------------------------------------------------------------
    # [4] Déclarations Metrics
    # ------------------------------------------------------------------
    my $metrics_src = _slurp_740(File::Spec->catfile('Mediabot', 'Metrics.pm'));
    for my $g (qw(users users_max channels servers operators)) {
        $assert->like($metrics_src, qr/'mediabot_network_$g',\s+'gauge'/,
            "Metrics: gauge network_$g declaree");
    }

    # ------------------------------------------------------------------
    # [5] Dashboard overview : structure + doc-truth
    # ------------------------------------------------------------------
    {
        my $raw = _slurp_740(File::Spec->catfile('contrib', 'grafana', 'grafana_mediabot_overview_v1.json'));
        my $dash = eval { JSON::PP->new->decode($raw) };
        $assert->ok(ref($dash) eq 'HASH', 'overview: JSON valide');

        my @tvars = @{ ($dash->{templating} || {})->{list} || [] };
        my %vars = map { ($_->{name} || '') => 1 } @tvars;
        $assert->ok($vars{bot} && $vars{channel} && $vars{DS_PROMETHEUS},
            'overview: variables bot/channel/datasource');

        # L'exigence du round: la rangee de stats est COMPACTE (h == 3).
        my @stats = grep { ($_->{type} || '') eq 'stat' } @{ $dash->{panels} || [] };
        $assert->ok(@stats >= 5, 'overview: au moins cinq stats en tete');
        my @tall = grep { (($_->{gridPos} || {})->{h} || 99) > 3 } @stats;
        $assert->ok(!@tall, 'overview: aucune stat plus haute que 3 unites (compacite exigee)');

        # Logos cliquables.
        $assert->like($raw, qr/https:\/\/grafana\.com/, 'overview: lien grafana.com');
        $assert->like($raw, qr/https:\/\/prometheus\.io/, 'overview: lien prometheus.io');
        $assert->like($raw, qr/Grafana_logo\.svg/, 'overview: logo grafana');
        $assert->like($raw, qr/Prometheus_software_logo\.svg/, 'overview: logo prometheus');

        # Doc-truth: chaque serie referencee existe (Metrics.pm ou plugin).
        my $plugin_src = _slurp_740(File::Spec->catfile('Mediabot', 'Plugin', 'ScriptDryRun.pm'));
        my %declared;
        while ($metrics_src =~ /_declare\('([a-z_]+)'/g) { $declared{$1} = 1 }
        while ($plugin_src =~ /'declare',\s*'(mediabot_scriptbridge_[a-z_]+)'/g) { $declared{$1} = 1 }

        my %used;
        while ($raw =~ /(mediabot_[a-z_]+)/g) {
            my $series = $1;
            # mb551: try the full name first (real series can end in _count),
            # then the histogram-suffix-stripped base name.
            unless ($declared{$series}) {
                (my $base = $series) =~ s/_(?:bucket|sum|count)\z//;
                $series = $base if $declared{$base};
            }
            $used{$series} = 1;
        }
        $assert->ok(scalar(keys %used) >= 10, 'overview: au moins dix series utilisees');
        for my $series (sort keys %used) {
            $assert->ok($declared{$series}, "overview -> code: '$series' est declaree");
        }
        for my $g (qw(mediabot_network_users mediabot_network_channels)) {
            $assert->ok($used{$g}, "code -> overview: '$g' est affichee");
        }
    }

    # ------------------------------------------------------------------
    # [6] Docs
    # ------------------------------------------------------------------
    {
        my $sample = _slurp_740('mediabot.sample.conf');
        $assert->like($sample, qr/^#LUSERS_REFRESH=300/m, 'sample: LUSERS_REFRESH documente');

        my $contrib = _slurp_740(File::Spec->catfile('contrib', 'grafana', 'README.md'));
        $assert->like($contrib, qr/grafana_mediabot_overview_v1\.json/, 'contrib README: overview reference');
    }
};
