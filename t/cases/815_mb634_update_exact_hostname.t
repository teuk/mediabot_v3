# t/cases/815_mb634_update_exact_hostname.t
# =============================================================================
# mb634 — la protection integree update vise le hostname ENTIER teuk.org.
# =============================================================================
use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

return sub {
    my ($assert) = @_;

    require Mediabot::Update;
    my $U = 'Mediabot::Update';
    my $hm = $U->can('_host_matches');
    $assert->ok($hm, 'mb634-815: matcher hostname disponible');

    for my $same ('teuk.org', 'TEUK.ORG', 'teuk.org.') {
        $assert->ok($hm->('teuk.org', [$same]),
            "mb634-815: '$same' est le meme hostname exact");
    }
    for my $other ('mediabot.teuk.org', 'foo-teuk.org', 'teuk.org.example',
                   'notteuk.org', '') {
        $assert->ok(!$hm->('teuk.org', [$other]),
            "mb634-815: '$other' n est PAS teuk.org");
    }
    $assert->ok(!$hm->('teuk.org', []),
        'mb634-815: hostname inconnu ne devient pas teuk.org');

    my $good = {
        'mediabot.pl' => 1,
        'install/deploy_update.sh' => 1,
        deploy_executable => 1,
        parent_writable => 1,
    };
    my @p = ({ path => '/home/mediabot/mediabot_v3', host => 'teuk.org' });

    my ($exact) = Mediabot::Update::update_eligibility(
        project_dir => '/home/mediabot/mediabot_v3',
        protected => \@p, hostnames => ['teuk.org'], exists => $good);
    my ($sub) = Mediabot::Update::update_eligibility(
        project_dir => '/home/mediabot/mediabot_v3',
        protected => \@p, hostnames => ['mediabot.teuk.org'], exists => $good);
    my ($unknown) = Mediabot::Update::update_eligibility(
        project_dir => '/home/mediabot/mediabot_v3',
        protected => \@p, hostnames => [], exists => $good);

    $assert->is($exact, 0, 'mb634-815: chemin prod + hote EXACT teuk.org refuse');
    $assert->is($sub, 1, 'mb634-815: meme chemin + sous-domaine teuk.org autorise');
    $assert->is($unknown, 1, 'mb634-815: meme chemin + hostname inconnu autorise');

    open my $fh, '<:encoding(UTF-8)', 'install/deploy_update.sh' or die $!;
    local $/;
    my $sh = <$fh>;
    close $fh;
    $assert->like($sh, qr/CURRENT_HOST_NORM="\$\{CURRENT_HOST,,\}"/,
        'mb634-815: shell normalise la casse');
    $assert->like($sh, qr/CURRENT_HOST_NORM="\$\{CURRENT_HOST_NORM%\.\}"/,
        'mb634-815: shell retire seulement le point DNS final');
    $assert->like($sh, qr/\[ "\$CURRENT_HOST_NORM" = "teuk\.org" \]/,
        'mb634-815: shell compare le hostname entier');
    $assert->ok($sh !~ /grep\s+-qi\s+["']?teuk\\\.org/i,
        'mb634-815: shell ne cherche plus teuk.org comme sous-chaine');
    $assert->ok($sh !~ /\[ "\$CURRENT_USER" = "mediabot" \].*teuk\.org/s,
        'mb634-815: garde exacte independante du compte Unix');
};
