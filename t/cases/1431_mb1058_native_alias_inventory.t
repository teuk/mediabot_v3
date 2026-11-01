use strict;
use warnings;
use Test::More;
use Scalar::Util qw(refaddr);
use Mediabot::Mediabot;
use Mediabot::Partyline;

# Fixed public/compatibility inventory, not discovered from the facade under test.
# A removed alias must fail. Implementation matrices run on the owner once;
# these references prove that calling an alias executes that exact same code.
for my $row (
    ['Mediabot::UserCommands', 'Mediabot', [qw(addUser_ctx delUser_ctx)]],
    ['Mediabot::CommunityState', 'Mediabot::UserCommands', [qw(
        mbRemind_ctx mbRemindList_ctx mbRemindCancel_ctx mbRemindSnooze_ctx deliverReminders
        mbPoll_ctx mbVote_ctx mbPollResult_ctx mbPollStop_ctx mbPollExtend_ctx
        mbPollStatus_ctx mbPollVoters_ctx mbUnvote_ctx _notes_ensure_loaded mbNote_ctx
        mbNotes_ctx _factoid_id_channel _factoid_enabled mbLearn_ctx mbWhatis_ctx
        mbForget_ctx mbFactoids_ctx mbFactoid_ctx
    )]],
    ['Mediabot::CommunityState', 'Mediabot', [qw(
        mbRemind_ctx mbRemindList_ctx mbRemindCancel_ctx mbRemindSnooze_ctx deliverReminders
        mbPoll_ctx mbVote_ctx mbPollResult_ctx mbPollStop_ctx mbPollExtend_ctx
        mbPollStatus_ctx mbPollVoters_ctx mbUnvote_ctx mbNote_ctx mbNotes_ctx
        mbLearn_ctx mbWhatis_ctx mbForget_ctx mbFactoids_ctx mbFactoid_ctx
    )]],
    ['Mediabot::Karma', 'Mediabot::UserCommands', [qw(
        mbKarma_ctx processKarma mbKarmaHist_ctx _karma_current_score mbKarmaWatch_ctx
        mbKarmaInfo_ctx mbKarmaGraph_ctx mbKarmaReset_ctx mbKarmaDiff_ctx mbKarmaTop_ctx
    )]],
    ['Mediabot::Karma', 'Mediabot', [qw(
        mbKarma_ctx processKarma mbKarmaHist_ctx mbKarmaWatch_ctx mbKarmaInfo_ctx
        mbKarmaGraph_ctx mbKarmaReset_ctx mbKarmaDiff_ctx mbKarmaTop_ctx
    )]],
    ['Mediabot::SocialHistory', 'Mediabot::UserCommands', [qw(
        _fmt_n _awards_add _awards_pick mbAwards_ctx _yearbook_best_key
        _yearbook_month_label _yearbook_day_label _yearbook_collect mbYearbook_ctx mbMemory_ctx
        _memory_rand_bounded _memory_lines _profile_community_footprint mbProfil_ctx mbDashboard_ctx
        mbMood_ctx mbLeaderboard_ctx mbChronos_ctx _recap_text _recap_parse
        _ach_progress mbRecap_ctx mbOnThisDay_ctx _onthisday_lines mbMilestone_ctx
        _milestone_next _milestone_last _group_int _humanize_days
    )]],
    ['Mediabot::SocialHistory', 'Mediabot', [qw(
        mbAwards_ctx mbYearbook_ctx mbMemory_ctx mbProfil_ctx mbDashboard_ctx
        mbMood_ctx mbLeaderboard_ctx mbChronos_ctx mbRecap_ctx mbOnThisDay_ctx
        mbMilestone_ctx
    )]],
    ['Mediabot::Games::Duel', 'Mediabot::UserCommands', [qw(
        mbDuel_ctx
    )]],
    ['Mediabot::Games::Duel', 'Mediabot', [qw(
        mbDuel_ctx
    )]],
    ['Mediabot::Games::Trivia', 'Mediabot::UserCommands', [qw(
        _trivia_fetch_async mbTrivia_ctx checkTriviaAnswer mbTriviaTop_ctx mbTriviaReset_ctx
        mbTriviaStop_ctx mbTriviaScore_ctx
    )]],
    ['Mediabot::Games::Trivia', 'Mediabot', [qw(
        mbTrivia_ctx checkTriviaAnswer mbTriviaTop_ctx mbTriviaReset_ctx mbTriviaStop_ctx
        mbTriviaScore_ctx
    )]],
    ['Mediabot::Users::Seen', 'Mediabot::UserCommands', [qw(
        mbSeen_ctx
    )]],
    ['Mediabot::Users::Seen', 'Mediabot', [qw(
        mbSeen_ctx
    )]],
    ['Mediabot::Partyline::Transport', 'Mediabot::Partyline', [qw(
        accept_dcc_chat _resolve_dcc_public_ip _dcc_listen_port _dcc_offer_key _dcc_pending_offer_for_nick
        _dcc_offer_register _dcc_offer_remove _dcc_offer_mark_connected _dcc_offers_snapshot offer_dcc_chat
        _dcc_token_hint accept_dcc_chat_passive _extract_input_lines _reject_oversized_input _dispatch_line_safely
        _report_operation_error _init_dcc_session _peer_ip_from_handle _start_listener
    )]],
    ['Mediabot::Partyline::SessionAuth', 'Mediabot::Partyline', [qw(
        _cancel_auth_timeout _close_session _reverse_dns_timeout _schedule_reverse_dns_lookup _display_nick
        _broadcast _broadcast_chat _telnet_echo_off _telnet_echo_on _strip_telnet_iac
        _pl_bf_blocked _pl_bf_record _pl_bf_clear _do_login
    )]],
    ['Mediabot::Partyline::Dispatcher', 'Mediabot::Partyline', [qw(
        _handle_line
    )]],
    ['Mediabot::Partyline::Commands', 'Mediabot::Partyline', [qw(
        _cmd_scriptdryrun _plugin_info_text _plugin_config_display_value _cmd_plugins _cmd_help
        _cmd_console _cmd_motd _send_motd _cmd_whom _cmd_match
        _cmd_boot _cmd_whois _cmd_log _cmd_timers _format_duration
        _seconds_to_human _cmd_schedule _cmd_status _cmd_metrics _cmd_channels
        _cmd_bcast _cmd_whochan _cmd_top _cmd_remind _cmd_seen
        _cmd_purgereminders _cmd_karma _cmd_karmahist _reload_configuration_file _cmd_reloadconf
        _cmd_reload _cmd_lusers _cmd_stats _cmd_join _cmd_part
        _cmd_nick _cmd_raw _cmd_rehash _cmd_restart _cmd_ai
        _cmd_persona _cmd_quota _cmd_ping _cmd_uptime _cmd_dccstat
        _cmd_stat _cmd_dbstats _cmd_bans _cmd_ban _cmd_unban
        _cmd_topic _cmd_kick _cmd_unmute _cmd_floodset _cmd_cmdcooldown
        _cmd_netsplit _cmd_floodstatus _cmd_flushcooldown _cmd_history _cmd_say
        _cmd_who _cmd_chanlog _cmd_nickinfo _cmd_who_chan _cmd_kv
        _cmd_achievementprofile
    )]],
    ['Mediabot::Partyline::Privileged', 'Mediabot::Partyline', [qw(
        _cmd_eval _cmd_die
    )]],
 ) {
    my ($owner,$facade,$names)=@$row;
    for my $name (@$names) {
        my $implementation=$owner->can($name);
        my $alias=$facade->can($name);
        ok($implementation && $alias && refaddr($implementation)==refaddr($alias),
            "$facade\::$name uses the native $owner implementation");
    }
}
done_testing;
