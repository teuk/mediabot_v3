# t/cases/861_mb677_community_state_extraction.t
use strict;
use warnings;

return sub {
    my ($assert) = @_;

    sub slurp861 {
        my ($path) = @_;
        open my $fh, '<:raw', $path or die "$path: $!";
        local $/;
        return <$fh>;
    }

    my $uc   = slurp861('Mediabot/UserCommands.pm');
    my $cs   = slurp861('Mediabot/CommunityState.pm');
    my $mb   = slurp861('Mediabot/Mediabot.pm');
    my $main = slurp861('mediabot.pl');

    $assert->like($cs, qr/^package Mediabot::CommunityState;/m,
        'mb677-861: dedicated CommunityState module exists');

    my @symbols = qw(
        mbRemind_ctx mbRemindList_ctx mbRemindCancel_ctx mbRemindSnooze_ctx
        deliverReminders
        mbPoll_ctx mbVote_ctx mbPollResult_ctx mbPollStop_ctx mbPollExtend_ctx
        mbPollStatus_ctx mbPollVoters_ctx mbUnvote_ctx
        _notes_ensure_loaded mbNote_ctx mbNotes_ctx
        _factoid_id_channel _factoid_enabled mbLearn_ctx mbWhatis_ctx
        mbForget_ctx mbFactoids_ctx mbFactoid_ctx
    );

    for my $name (@symbols) {
        $assert->unlike($uc, qr/^sub \Q$name\E \{/m,
            "mb677-861: $name implementation left UserCommands");
        $assert->like($cs, qr/^sub \Q$name\E \{/m,
            "mb677-861: $name implementation lives in CommunityState");
        $assert->like($uc, qr/^\s*\Q$name\E\s*$/m,
            "mb677-861: $name remains imported into UserCommands");
    }

    $assert->like($uc, qr/use Mediabot::CommunityState qw\(/,
        'mb677-861: UserCommands imports CommunityState compatibility symbols');

    for my $bridge (qw(
        botPrivmsg botNotice logBot _seconds_to_human isIrcChannelTarget
        truncate_utf8 getIdUserChannelLevel
    )) {
        $assert->like($cs,
            qr/^sub \Q$bridge\E\s+\{\s*goto &Mediabot::UserCommands::\Q$bridge\E\s*\}/m,
            "mb677-861: $bridge compatibility trampoline is explicit");
    }

    for my $export (qw(
        mbRemind_ctx mbRemindList_ctx mbRemindCancel_ctx mbRemindSnooze_ctx
        deliverReminders mbPoll_ctx mbVote_ctx mbPollResult_ctx mbPollStop_ctx
        mbPollExtend_ctx mbPollStatus_ctx mbPollVoters_ctx mbUnvote_ctx
        mbNote_ctx mbNotes_ctx mbLearn_ctx mbWhatis_ctx mbForget_ctx
        mbFactoids_ctx mbFactoid_ctx
    )) {
        $assert->like($uc, qr/^\s*\Q$export\E\s*$/m,
            "mb677-861: historical UserCommands export remains for $export");
    }

    for my $dispatch (qw(
        remind remindlist tell remindsnooze pollextend learn whatis forget
        factoids factoid poll vote pollresult pollstatus pollvoters unvote
        pollstop note notes
    )) {
        $assert->like($mb, qr/^\s*\Q$dispatch\E\s*=>/m,
            "mb677-861: $dispatch dispatch key remains present");
    }

    $assert->like($cs, qr/\bREMINDERS\b/,
        'mb677-861: reminder persistence remains with extracted implementation');
    $assert->like($cs, qr/\{_polls\}|\{_poll\}/,
        'mb677-861: poll state remains with extracted implementation');
    $assert->like($cs, qr/\bNOTE\b/,
        'mb677-861: note persistence remains with extracted implementation');
    $assert->like($cs, qr/\bFACTOID\b/,
        'mb677-861: factoid persistence remains with extracted implementation');
    $assert->like($cs, qr/check_community_contributions\(/,
        'mb677-861: factoid achievement hook remains with extracted implementation');

    $assert->like($main, qr/Mediabot::UserCommands::deliverReminders\s*\(/,
        'mb677-861: historical fully-qualified deliverReminders call remains valid');

    my $uc_lines = () = $uc =~ /\n/g;
    $assert->ok($uc_lines < 8700,
        'mb677-861: extraction materially shrinks UserCommands below 8.7k lines');

    require Mediabot::UserCommands;
    require Mediabot::CommunityState;

    for my $name (@symbols) {
        $assert->ok(Mediabot::CommunityState->can($name),
            "mb677-861: Mediabot::CommunityState resolves $name");
        $assert->ok(Mediabot::UserCommands->can($name),
            "mb677-861: historical Mediabot::UserCommands symbol resolves $name");
    }
};
