# t/cases/814_mb632_irc_update_command.t
# =============================================================================
# mb632 — « m update » / « /msg bot update » : mise a jour depuis GitHub.
#
# Cette commande remplace le code du bot par lui-meme : elle est donc ecrite
# et testee a l'envers des autres — d'abord tout ce qui REFUSE. L'echange reel
# (clone, bascule de repertoires, SIGTERM) ne se rejoue pas dans une suite ;
# ce qui se prouve, ce sont les DECISIONS, et elles sont pures pour cette
# raison precise.
#
#   [1] protection integree : /home/mediabot/mediabot_v3 est refuse UNIQUEMENT
#       sur l'hote entier teuk.org ; la conf ne peut qu'AJOUTER des protections.
#   [2] eligibilite de la machine : nom du repertoire, presence de
#       mediabot.pl et du script, bit executable, parent inscriptible.
#   [3] decision de version : disponible / a jour / local en avance /
#       illisible / incomparable — et « en avance » ne declenche RIEN.
#   [4] niveau Master exige, pose AVANT toute autre chose.
#   [5] « update » seul ne fait QUE diagnostiquer ; seul « now » agit.
#   [6] le mode de redemarrage est detecte et ANNONCE (le script n'est pas
#       cense relancer le bot : sans systemd, il reste eteint).
#   [7] les deux portes (script shell et commande IRC) disent la meme chose.
# =============================================================================

use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

{
    package ConfU;
    sub new { bless { kv => $_[1] || {} }, $_[0] }
    sub get { $_[0]{kv}{ $_[1] } }
}
{ package LogU; sub new { bless {}, shift } sub log { 1 } }
{
    package CtxU;
    sub new { my ($c,%a)=@_; bless { %a, asked => [] }, $c }
    sub bot { $_[0]{bot} } sub nick { 'teuk' }
    sub channel { $_[0]{channel} } sub args { $_[0]{args} || [] }
    sub message { {} }
    sub require_level {
        my ($s, $lvl) = @_;
        push @{ $s->{asked} }, $lvl;
        return $s->{allow} ? 1 : 0;
    }
}

return sub {
    my ($assert) = @_;

    require Mediabot::Update;
    require Mediabot::Helpers;
    my $U = 'Mediabot::Update';

    my $good = { 'mediabot.pl' => 1, 'install/deploy_update.sh' => 1,
                 deploy_executable => 1, parent_writable => 1 };

    # [1] mb633/mb634 : la protection integree est le couple
    # /home/mediabot/mediabot_v3 @ hote EXACT teuk.org.
    # Une simple sous-chaine ne suffit jamais.
    my @P = ({ path => '/home/mediabot/mediabot_v3', host => 'teuk.org' });
    my %host_cases = (
        'hote exact teuk.org'        => [ '/home/mediabot/mediabot_v3', ['teuk.org'],           0 ],
        'casse ignoree'              => [ '/home/mediabot/mediabot_v3', ['TEUK.ORG'],           0 ],
        'point DNS final'            => [ '/home/mediabot/mediabot_v3', ['teuk.org.'],          0 ],
        'sous-domaine'               => [ '/home/mediabot/mediabot_v3', ['mediabot.teuk.org'],  1 ],
        'prefixe contenant le nom'   => [ '/home/mediabot/mediabot_v3', ['foo-teuk.org'],       1 ],
        'suffixe apres le nom'       => [ '/home/mediabot/mediabot_v3', ['teuk.org.example'],   1 ],
        'autre serveur'              => [ '/home/mediabot/mediabot_v3', ['nbot.soyou.rocks'],   1 ],
        'dev sur teuk.org'           => [ '/home/teuk/mediabot_v3',     ['teuk.org'],           1 ],
        'slash final + hote exact'   => [ '/home/mediabot/mediabot_v3/',['teuk.org'],           0 ],
        'hote inconnu'               => [ '/home/mediabot/mediabot_v3', [],                     1 ],
    );
    my $right = 0;
    for my $label (sort keys %host_cases) {
        my ($dir, $names, $want) = @{ $host_cases{$label} };
        my ($o) = $U->can('update_eligibility')->(
            project_dir => $dir, protected => \@P, hostnames => $names, exists => $good);
        $right++ if $o == $want;
    }
    $assert->is($right, scalar(keys %host_cases),
        'mb634-814: seul le couple chemin + hote ENTIER teuk.org est refuse');

    my ($ok, $why) = $U->can('update_eligibility')->(
        project_dir => '/home/teuk/mediabot_v3', protected => \@P,
        hostnames => ['teuk.org'], exists => $good);
    $assert->is($ok, 1, 'mb632-814: une instance de dev normale est autorisee');

    # la conf AJOUTE des protections, elle n'en retire aucune
    my $bot_extra = bless { conf => ConfU->new({
        'update.PROTECTED_PATHS' => '/srv/bot1, /srv/bot2@other.example' }) }, 'Mediabot';
    my @entries = $U->can('protected_paths')->($bot_extra);
    my ($builtin) = grep { $_->{path} eq '/home/mediabot/mediabot_v3' } @entries;
    $assert->ok($builtin && ($builtin->{host} // '') eq 'teuk.org',
        'mb633-814: la protection integree survit a une conf personnalisee, hote compris');
    $assert->is(scalar @entries, 3, 'mb632-814: ... et la conf en ajoute bien deux');
    my ($bare) = grep { $_->{path} eq '/srv/bot1' } @entries;
    $assert->ok($bare && !defined $bare->{host},
        'mb633-814: une entree conf SANS hote vaut partout (choix de l operateur)');
    my ($scoped) = grep { $_->{path} eq '/srv/bot2' } @entries;
    $assert->is(($scoped->{host} // ''), 'other.example',
        'mb633-814: ... et la forme chemin@hote est comprise');
    my $bot_empty = bless { conf => ConfU->new({ 'update.PROTECTED_PATHS' => '' }) }, 'Mediabot';
    $assert->ok((grep { $_->{path} eq '/home/mediabot/mediabot_v3' }
                 $U->can('protected_paths')->($bot_empty)),
        'mb632-814: une conf VIDE ne desarme pas la protection');

    # Un host scope de conf suit la MEME semantique exacte.
    my ($scope_exact) = $U->can('update_eligibility')->(
        project_dir => '/srv/bot2', protected => [ { path => '/srv/bot2', host => 'other.example' } ],
        hostnames => ['other.example'], exists => $good);
    my ($scope_sub) = $U->can('update_eligibility')->(
        project_dir => '/srv/bot2', protected => [ { path => '/srv/bot2', host => 'other.example' } ],
        hostnames => ['sub.other.example'], exists => $good);
    # Ces chemins ne passent pas le nom mediabot_v3 ensuite ; on appelle donc
    # directement le matcher prive pour isoler le contrat de hostname.
    my $hm = $U->can('_host_matches');
    $assert->ok($hm && $hm->('other.example', ['other.example']),
        'mb634-814: host scope exact = match');
    $assert->ok(!$hm->('other.example', ['sub.other.example']),
        'mb634-814: host scope en sous-domaine != match');

    my $names = [ $U->can('current_hostnames')->() ];
    $assert->ok(scalar @$names >= 1,
        'mb633-814: au moins un nom d hote est trouve sur cette machine');

    # [2] eligibilite de la machine
    my %broken = (
        'nom de repertoire'      => [ '/home/teuk/mediabot_v4', $good, qr/unexpected project directory/ ],
        'mediabot.pl absent'     => [ '/home/teuk/mediabot_v3', { %$good, 'mediabot.pl' => 0 }, qr/mediabot\.pl not found/ ],
        'script absent'          => [ '/home/teuk/mediabot_v3', { %$good, 'install/deploy_update.sh' => 0 }, qr/deploy_update\.sh not found/ ],
        'script non executable'  => [ '/home/teuk/mediabot_v3', { %$good, deploy_executable => 0 }, qr/not executable/ ],
        'parent non inscriptible'=> [ '/home/teuk/mediabot_v3', { %$good, parent_writable => 0 }, qr/not writable/ ],
    );
    my $refused = 0;
    for my $label (sort keys %broken) {
        my ($d, $ex, $re) = @{ $broken{$label} };
        my ($o, $w) = $U->can('update_eligibility')->(project_dir => $d, exists => $ex,
            protected => \@P, hostnames => ['dev.example']);
        $refused++ if !$o && $w =~ $re;
    }
    $assert->is($refused, scalar(keys %broken),
        'mb632-814: chaque prerequis manquant refuse avec sa raison');
    my ($no_dir) = $U->can('update_eligibility')->(project_dir => undef, exists => $good,
        protected => \@P, hostnames => ['dev.example']);
    $assert->is($no_dir, 0, 'mb632-814: repertoire irresolvable = refus');

    # [3] decisions de version
    my $cmp = Mediabot::Helpers->can('_compare_mediabot_versions');
    $assert->ok($cmp, 'mb632-814: le comparateur existant est reutilise');
    my %cases = (
        available  => [ '3.4dev-20260811_113500', '3.4dev-20260812_090000' ],
        up_to_date => [ '3.4dev-20260812_090000', '3.4dev-20260812_090000' ],
        ahead      => [ '3.4dev-20260813_000000', '3.4dev-20260812_090000' ],
    );
    for my $want (sort keys %cases) {
        my $d = $U->can('update_decision')->(
            local => $cases{$want}[0], remote => $cases{$want}[1], compare => $cmp);
        $assert->is($d->{state}, $want, "mb632-814: etat '$want' reconnu");
        $assert->is($d->{available}, ($want eq 'available' ? 1 : 0),
            "mb632-814: ... et il ne declenche une maj que si c'est le cas");
    }
    for my $bad ([ 'Undefined', '3.4dev-1' ], [ '3.4dev-1', 'Undefined' ], [ undef, undef ]) {
        my $d = $U->can('update_decision')->(
            local => $bad->[0], remote => $bad->[1], compare => $cmp);
        $assert->is($d->{state}, 'unreadable',
            'mb632-814: une version illisible ne devient jamais une mise a jour');
    }
    my $inc = $U->can('update_decision')->(
        local => 'x', remote => 'y', compare => sub { undef });
    $assert->is($inc->{state}, 'incomparable',
        'mb632-814: deux versions incomparables ne declenchent rien');

    # [4] niveau Master, pose en premier
    my @out;
    no warnings 'redefine';
    local *Mediabot::Helpers::botPrivmsg = sub { push @out, $_[2]; 1 };
    local *Mediabot::Helpers::botNotice  = sub { push @out, $_[2]; 1 };
    local *Mediabot::Helpers::logBot     = sub { 1 };
    my $spawned = 0;
    local *Mediabot::Update::_spawn_updater = sub { $spawned++; 1 };
    my $checked = 0;
    local *Mediabot::Helpers::getVersion_async = sub { $checked++; 1 };

    my $bot = bless { conf => ConfU->new, logger => LogU->new }, 'Mediabot';
    my $denied = CtxU->new(bot => $bot, allow => 0, channel => '#c', args => []);
    @out = ();
    Mediabot::Update::update_ctx($denied);
    $assert->is(join(',', @{ $denied->{asked} }), 'Master',
        'mb632-814: le niveau exige est Master');
    $assert->is(scalar @out, 0,
        'mb632-814: un refus ne dit rien de plus (require_level parle deja)');
    $assert->is($checked, 0, 'mb632-814: ... et n interroge pas GitHub');
    $assert->is($spawned, 0, 'mb632-814: ... et ne lance rien');

    # [5] « update » seul ne fait que diagnostiquer
    my $src = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/Update.pm'
        or die $!; local $/; <$fh> };
    $assert->like($src, qr/my \$do_it = \(\$verb eq 'now' \|\| \$verb eq 'go' \|\| \$verb eq 'confirm'\) \? 1 : 0;/,
        'mb632-814: seuls now/go/confirm declenchent l action');
    $assert->like($src, qr/unless \(\$do_it\) \{.*?run \\x02update now\\x02 to apply it/s,
        'mb632-814: sans « now », la commande explique comment agir');
    $assert->like($src, qr/_spawn_updater/,
        'mb632-814: le lancement existe');
    my ($after_doit) = $src =~ /unless \(\$do_it\) \{(.*?)\n        \}/s;
    $assert->ok(defined $after_doit && $after_doit !~ /_spawn_updater/,
        'mb632-814: ... mais JAMAIS dans la branche diagnostic');
    $assert->like($src, qr/unknown option '\$verb'/,
        'mb632-814: un mot inconnu est signale, pas ignore');

    # [6] redemarrage detecte et annonce
    $assert->is($U->can('restart_mode')->({ INVOCATION_ID => 'x' }), 'systemd',
        'mb632-814: systemd est reconnu');
    $assert->is($U->can('restart_mode')->({ JOURNAL_STREAM => '8:123' }), 'systemd',
        'mb632-814: ... par ses deux marqueurs');
    $assert->is($U->can('restart_mode')->({}), 'manual',
        'mb632-814: hors systemd, mode manuel');
    $assert->like($src, qr/restart policy is verified before shutdown/,
        'mb645-814: systemd detecte ne vaut plus promesse aveugle, le script verifie la policy');
    $assert->like($src, qr/the bot will STAY DOWN until you start it again/,
        'mb632-814: le mode manuel est ANNONCE — le script ne relance pas le bot');

    # le detachement : le script nous tue, on ne doit pas etre son parent vivant
    $assert->like($src, qr/setsid\(\)/, 'mb632-814: le processus de mise a jour se detache');
    $assert->like($src, qr/my \$second = fork\(\);/,
        'mb632-814: double fork — aucun zombie si le bot meurt avant');
    $assert->like($src, qr/open\(STDOUT, '>>', \$log\)/,
        'mb632-814: la sortie du script est conservee dans un journal');

    # [7] les deux portes disent la meme chose
    my $sh = do { open my $fh, '<:encoding(UTF-8)', 'install/deploy_update.sh'
        or die $!; local $/; <$fh> };
    $assert->like($sh, qr{/home/mediabot/mediabot_v3},
        'mb632-814: le script protege toujours le meme chemin');
    $assert->ok($sh !~ /Use the IRC command or a manual procedure/,
        'mb632-814: il ne renvoie plus vers une commande qui refuse aussi');
    $assert->like($sh, qr/The IRC 'update' command refuses this exact path\+host pair too/,
        'mb634-814: ... les deux portes sont coherentes sur le couple exact path+host');
    $assert->like($sh, qr/cp -pfv "\$\{PROJECT_DIR\}\/mediabot\.conf"/,
        'mb632-814: la conf est toujours preservee par le script');
    $assert->like($sh, qr/LATEST_BRAIN/,
        'mb632-814: le cerveau Hailo aussi');
};
