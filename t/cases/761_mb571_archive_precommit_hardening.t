# t/cases/761_mb571_archive_precommit_hardening.t
# =============================================================================
# mb571 — hardening pre-commit des rounds mb565..mb570 :
#   - archivage scheduler forke avec DB isolee, jamais synchrone dans IO::Async ;
#   - verification d'identite exacte + MAX_PER_RUN strict ;
#   - purge legacy fail-closed quand l'archive SQL est configuree ;
#   - normalize: un ADD echoue interdit tous les DROP projetes ;
#   - documentation honnette: seul onthisday est archive-aware aujourd'hui.
# =============================================================================
use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_761 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;
    my $mod  = _slurp_761(File::Spec->catfile('Mediabot', 'Mediabot.pm'));
    my $main = _slurp_761('mediabot.pl');
    my $norm = _slurp_761(File::Spec->catfile('tools', 'normalize_channel_log_indexes.pl'));
    my $sample = _slurp_761('mediabot.sample.conf');

    $assert->like($main, qr/start_channel_log_archive_async/,
        'scheduler appelle le lanceur async');
    $assert->unlike($main, qr/\$mediabot->archive_channel_log\(\)/,
        'scheduler ne lance jamais le gros SQL synchroniquement');

    my ($async) = $mod =~ /(sub start_channel_log_archive_async \{.*?\n\})/s;
    $assert->ok(defined $async, 'lanceur async present');
    $assert->like($async // '', qr/fork\(\)/, 'worker forke');
    $assert->like($async // '', qr/connect_isolated_handle/, 'connexion DB isolee');
    $assert->like($async // '', qr/InactiveDestroy/, 'handles parents proteges');
    $assert->like($async // '', qr/watch_process/, 'processus reap par IO::Async');
    $assert->like($async // '', qr/POSIX::_exit/, 'sortie enfant sans destructeurs parents');

    my ($arch) = $mod =~ /(sub archive_channel_log \{.*?\n\})/s;
    $assert->like($arch // '', qr/JOIN CHANNEL_LOG live/, 'verification compare archive et vif');
    $assert->like($arch // '', qr/publictext/, 'verification inclut le contenu');
    $assert->like($arch // '', qr/my \$remaining = \$max_run - \$total/,
        'MAX_PER_RUN strict sur le dernier lot');

    my ($purge) = $mod =~ /(sub purge_channel_log \{.*?\n\})/s;
    $assert->like($purge // '', qr/CHANNEL_LOG_ARCHIVE_DBNAME/,
        'purge legacy refusee quand archive configuree');

    $assert->like($norm, qr/if \(\$verb eq 'DROP' && \$add_failed\)/,
        'normalize saute les DROP projetes apres echec ADD');
    # mb584: le pipeline traite desormais vif + archive — le code retour
    # agrege les echecs des deux tables (run_table retourne $failed).
    $assert->like($norm, qr/exit\(\$total_failed \? 2 : 0\)/,
        'normalize retourne non-zero si une action echoue');

    $assert->like($sample, qr/Other lifetime commands\/achievements still read only\n# the live table/,
        'sample documente la fenetre historique des autres commandes');
};
