# t/cases/852_mb670_social_history_extraction.t
use strict;
use warnings;

return sub {
    my ($assert) = @_;

    sub slurp852 {
        my ($path) = @_;
        open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
        local $/;
        return <$fh>;
    }

    my $uc = slurp852('Mediabot/UserCommands.pm');
    my $sh = slurp852('Mediabot/SocialHistory.pm');
    my $mb = slurp852('Mediabot/Mediabot.pm');

    $assert->like($sh, qr/^package Mediabot::SocialHistory;/m,
        'mb670-852: dedicated SocialHistory module exists');

    my @commands = qw(
        mbProfil_ctx mbDashboard_ctx mbMood_ctx mbLeaderboard_ctx mbChronos_ctx
        mbRecap_ctx mbOnThisDay_ctx mbMemory_ctx mbMilestone_ctx mbAwards_ctx
        mbYearbook_ctx
    );
    for my $name (@commands) {
        $assert->unlike($uc, qr/^sub \Q$name\E \{/m,
            "mb670-852: $name implementation left UserCommands");
        $assert->like($sh, qr/^sub \Q$name\E \{/m,
            "mb670-852: $name implementation lives in SocialHistory");
        $assert->like($uc, qr/^\s*\Q$name\E\s*$/m,
            "mb670-852: $name remains in UserCommands export/import contract");
    }

    my @helpers = qw(
        _profile_community_footprint _recap_text _recap_parse _ach_progress
        _onthisday_lines _milestone_next _milestone_last _group_int
        _humanize_days _memory_lines _awards_pick _yearbook_collect _fmt_n
    );
    for my $helper (@helpers) {
        $assert->unlike($uc, qr/^sub \Q$helper\E \{/m,
            "mb670-852: $helper implementation left UserCommands");
        $assert->like($sh, qr/^sub \Q$helper\E \{/m,
            "mb670-852: $helper implementation lives in SocialHistory");
    }

    $assert->like($uc, qr/use Mediabot::SocialHistory qw\(/,
        'mb670-852: UserCommands imports SocialHistory compatibility symbols');

    for my $bridge (qw(botPrivmsg botNotice queueBotNotices isIrcChannelTarget _ach_goal_line _irc_bytes)) {
        $assert->like($sh,
            qr/^sub \Q$bridge\E\s+\{\s*goto &Mediabot::UserCommands::\Q$bridge\E\s*\}/m,
            "mb670-852: $bridge compatibility trampoline is explicit");
    }

    $assert->like($sh,
        qr/Mediabot::UserCommands::_profile_community_footprint\(\$self,\s*\$dbh,\s*\$channel,\s*\$target\)/,
        'mb670-852: profile keeps UserCommands mock/plugin compatibility seam');
    $assert->like($sh,
        qr/Mediabot::UserCommands::_onthisday_lines\(\$self,\s*\$id_channel,\s*\$channel,\s*%date_opts\)/,
        'mb670-852: onthisday keeps shared helper compatibility seam');

    for my $dispatch (qw(profile profil dashboard mood leaderboard awards yearbook chronos recap onthisday memory milestone)) {
        $assert->like($mb, qr/^\s*\Q$dispatch\E\s*=>/m,
            "mb670-852: $dispatch dispatch key remains present");
    }

    my $uc_lines = () = $uc =~ /\n/g;
    $assert->ok($uc_lines < 11200,
        'mb670-852: completed extraction materially shrinks UserCommands below 11.2k lines');

    my $write_sql = (
        $sh =~ /(?:q|qq)\s*\{\s*(?:INSERT|UPDATE|DELETE|REPLACE|CREATE|ALTER|DROP)\b/is
        || $sh =~ /\$dbh->(?:prepare|do)\(\s*["']\s*(?:INSERT|UPDATE|DELETE|REPLACE|CREATE|ALTER|DROP)\b/is
    );
    $assert->ok(!$write_sql,
        'mb670-852: extracted social/history module introduces no write SQL');
};
