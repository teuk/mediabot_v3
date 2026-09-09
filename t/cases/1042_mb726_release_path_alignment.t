# MB726 — installation, update, database, systemd and release paths agree.

use strict;
use warnings;
use utf8;

sub _slurp_1042 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

sub _migration_order_1042 {
    my ($text, $heading) = @_;
    my ($block) = $text =~ /\Q$heading\E.*?```text\s*(.*?)```/s;
    return [] unless defined $block;
    return [ $block =~ /^([A-Za-z0-9_]+\.sql)$/mg ];
}

return sub {
    my ($assert) = @_;

    my $release = _slurp_1042('docs/RELEASING.md');
    my $deploy_doc = _slurp_1042('docs/A3_deploiement_integrity.md');
    my $db_doc = _slurp_1042('docs/DB_MIGRATIONS.md');
    my $migration_doc = _slurp_1042('install/migrations/README.md');
    my $systemd_doc = _slurp_1042('tools/systemd/README.md');
    my $template = _slurp_1042('tools/systemd/mediabot@.service.example');
    my $builder = _slurp_1042('tools/build_release_artifacts.sh');
    my $deployer = _slurp_1042('install/deploy_update.sh');

    $assert->ok(!-e 'tools/update_remote.sh',
        'mb726: obsolete remote updater is absent');
    $assert->like($builder, qr/tools\/update_remote\\\.sh\$/,
        'mb726: public archives reject the obsolete updater path');
    $assert->like($deploy_doc,
        qr/install\/deploy_update\.sh` est l'unique déployeur IRC supporté/,
        'mb726: deployment guide names one supported IRC updater');
    $assert->like($deploy_doc, qr/L'ancien `tools\/update_remote\.sh` a été retiré/,
        'mb726: deployment guide records the removed unsafe helper');
    $assert->like($deployer, qr/Usage:\s+install\/deploy_update\.sh \[--conf=<file>\]/s,
        'mb726: supported deployer exposes the documented config option');

    for my $path (
        './configure',
        'install/db_migrate.sh',
        'install/deploy_update.sh',
        'install/systemd_install.sh',
        'install/mbweb_deploy.sh',
        'tools/rehearse_release_artifacts.sh',
        'tools/build_release_artifacts.sh',
    ) {
        $assert->like($release, qr/\Q$path\E/,
            "mb726: release guide names authority $path");
    }

    for my $doc ($db_doc, $migration_doc) {
        $assert->like($doc,
            qr/sudo mariadb --protocol=socket --default-character-set=utf8mb4/,
            'mb726: migration guide uses the Debian 13 MariaDB socket path');
        $assert->like($doc, qr/mariadb -u root -p --default-character-set=utf8mb4/,
            'mb726: password-auth compatibility remains explicit and interactive');
        $assert->unlike($doc, qr/^mysql -u root -p/m,
            'mb726: migration guide has no obsolete primary mysql invocation');
    }

    my $public_order = _migration_order_1042($db_doc, '## Migration order');
    my $operator_order = _migration_order_1042($migration_doc, '## Current migration order');
    $assert->ok(@$public_order > 0, 'mb726: public migration order is present');
    $assert->is(join("\n", @$public_order), join("\n", @$operator_order),
        'mb726: both migration guides expose the exact same ordered files');
    # MB732: the stable quote migration remains in the ordered history when
    # development appends Quip or later migrations. Do not freeze the tail.
    my @quote_positions = grep {
        $public_order->[$_] eq '20260905_quotes_512_contract.sql'
    } 0 .. $#$public_order;
    my @quip_positions = grep {
        $public_order->[$_] eq '20260909_quip_chanset.sql'
    } 0 .. $#$public_order;
    $assert->is(scalar(@quote_positions), 1,
        'mb726: quote contract remains exactly once in the ordered history');
    $assert->is(scalar(@quip_positions), 1,
        'mb732: Quip registration appears exactly once in the ordered history');
    $assert->ok(@quote_positions == 1 && @quip_positions == 1
            && $quote_positions[0] < $quip_positions[0],
        'mb732: Quip registration follows the stable quote contract');

    for my $directive (
        'ExitType=cgroup',
        'Environment=MEDIABOT_SYSTEMD_UPDATE_SAFE=1',
        'Restart=always',
        'SuccessExitStatus=75',
        'RestartPreventExitStatus=75',
    ) {
        $assert->like($template, qr/^\Q$directive\E$/m,
            "mb726: published template contains $directive");
        $assert->like($systemd_doc, qr/^\Q$directive\E$/m,
            "mb726: systemd guide documents $directive");
    }
};
