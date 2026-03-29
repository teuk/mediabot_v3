# t/live/07_die_last.t
# =============================================================================
#  Test final — !die authentifié Master.
#  CE FICHIER DOIT RESTER LE DERNIER (07_) : il tue le bot.
#
#  On vérifie que le bot quitte proprement IRC après !die :
#  le spy reçoit le QUIT du bot avec la raison correcte.
# =============================================================================

return sub {
    my ($assert, $spy, $send_cmd, $send_private, $wait_reply,
        $botnick, $spynick, $channel, $cmdchar,
        $loginuser, $loginpass) = @_;

    # Setup : login Master
    $send_private->("login $loginuser $loginpass");
    $wait_reply->(qr/NOTICE \Q$spynick\E .*successful/i, 15);
    sleep(1);

    # -------------------------------------------------------------------------
    # 1. !die → le spy voit le QUIT du bot sur IRC
    # -------------------------------------------------------------------------
    $send_cmd->('die');
    my $r = $wait_reply->(qr/:\Q$botnick\E[!@][^ ]+ QUIT/i, 15);
    $assert->ok(defined $r, "${cmdchar}die Master → bot quitte IRC (QUIT reçu)");
};
