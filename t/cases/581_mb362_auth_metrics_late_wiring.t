# t/cases/581_mb362_auth_metrics_late_wiring.t
# =============================================================================
# mb362 — La jauge des sessions Auth doit être réellement raccordée à Metrics.
#
# Au démarrage, init_auth() précède volontairement la création du loop et de
# Mediabot::Metrics. Auth implémentait déjà la mise à jour de
# mediabot_auth_sessions_total, mais ne recevait jamais l'objet Metrics : la
# jauge restait donc absente/stale. Ce test couvre le raccordement tardif, la
# synchronisation immédiate et les chemins de construction alternatifs.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;
use Mediabot::Auth;

{
    package MB362::Metrics;

    sub new {
        return bless { sets => [] }, shift;
    }

    sub set {
        my ($self, $name, $value) = @_;
        push @{ $self->{sets} }, [ $name, $value ];
        return 1;
    }

    sub last_value {
        my ($self) = @_;
        return undef unless @{ $self->{sets} };
        return $self->{sets}[-1][1];
    }
}

sub _slurp_581 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $metrics = MB362::Metrics->new;
    my $auth = Mediabot::Auth->new(metrics => $metrics);

    $assert->is(scalar @{ $metrics->{sets} }, 1,
        'constructeur avec Metrics publie immédiatement la jauge');
    $assert->is($metrics->{sets}[0][0], 'mediabot_auth_sessions_total',
        'nom de jauge Auth conservé');
    $assert->is($metrics->last_value, 0,
        'constructeur publie explicitement zéro session');

    $auth->{sessions} = {
        alice => { id_user => 1, logged_in_at => time() },
        bob   => { id_user => 2, logged_in_at => time() },
    };
    $auth->{logged_in} = { 1 => 1, 2 => 1 };

    $assert->ok($auth->_update_auth_session_metric(),
        'helper de métrique reste opérationnel après construction');
    $assert->is($metrics->last_value, 2,
        'helper publie le nombre réel de sessions');

    my $late_metrics = MB362::Metrics->new;
    $assert->ok($auth->set_metrics($late_metrics),
        'raccordement tardif accepte un objet Metrics valide');
    $assert->is($late_metrics->last_value, 2,
        'raccordement tardif synchronise immédiatement la valeur courante');

    $assert->ok($auth->logout('Alice'),
        'logout par nick réussit après raccordement tardif');
    $assert->is($late_metrics->last_value, 1,
        'logout par nick met la jauge à jour');
    $assert->ok($auth->logout(2),
        'logout par uid réussit après raccordement tardif');
    $assert->is($late_metrics->last_value, 0,
        'logout du dernier utilisateur remet la jauge à zéro');

    $assert->ok(!$auth->set_metrics('not-an-object'),
        'raccordement invalide échoue proprement');
    $assert->ok(!defined $auth->{metrics},
        'raccordement invalide ne laisse pas de faux objet Metrics');

    my $auth_src = _slurp_581(File::Spec->catfile('.', 'Mediabot', 'Auth.pm'));
    $assert->like($auth_src,
        qr/sub set_metrics\s*\{.*?_update_auth_session_metric\(\);/s,
        'Auth expose un setter tardif avec synchronisation immédiate');
    $assert->like($auth_src, qr/metrics\s*=>\s*\$args\{metrics\}/,
        'constructeur Auth conserve le Metrics fourni');
    $assert->like($auth_src,
        qr/\$self->set_metrics\(\$args\{metrics\}\) if \$args\{metrics\}/,
        'constructeur Auth initialise aussi la jauge quand Metrics existe déjà');
    $assert->like($auth_src, qr/mb362-B1/,
        'tag mb362-B1 présent dans Auth.pm');

    my $main_src = _slurp_581(File::Spec->catfile('.', 'mediabot.pl'));
    my $auth_pos    = index($main_src, '$mediabot->init_auth();');
    my $metrics_pos = index($main_src, '$mediabot->{metrics} = Mediabot::Metrics->new(');
    my $wire_pos    = index($main_src, '$mediabot->{auth}->set_metrics($mediabot->{metrics});');
    my $start_pos   = index($main_src, '$mediabot->{metrics}->start_http_server();');

    $assert->ok($auth_pos >= 0 && $metrics_pos > $auth_pos,
        'ordre historique Auth avant Metrics est conservé');
    $assert->ok($wire_pos > $metrics_pos,
        'Auth est raccordé après la création réelle de Metrics');
    $assert->ok($start_pos > $wire_pos,
        'jauge Auth synchronisée avant le démarrage de l’endpoint Metrics');
    $assert->like($main_src, qr/mb362-B1/,
        'tag mb362-B1 présent dans le démarrage principal');

    my @constructor_files = (
        File::Spec->catfile('.', 'Mediabot', 'LoginCommands.pm'),
        File::Spec->catfile('.', 'Mediabot', 'User.pm'),
        File::Spec->catfile('.', 'Mediabot', 'Helpers.pm'),
    );
    my $constructors = join "\n", map { _slurp_581($_) } @constructor_files;
    my $new_count     = () = $constructors =~ /Mediabot::Auth->new\s*\(/g;
    my $metrics_count = () = $constructors =~ /metrics\s*=>\s*\$(?:self|bot)->\{metrics\}/g;

    $assert->is($new_count, 6,
        'six chemins alternatifs de construction Auth recensés');
    $assert->is($metrics_count, $new_count,
        'chaque construction alternative transmet désormais Metrics');
};
