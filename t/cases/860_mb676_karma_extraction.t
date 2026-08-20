# t/cases/860_mb676_karma_extraction.t
use strict;
use warnings;

return sub {
    my ($assert) = @_;

    sub slurp860 {
        my ($path) = @_;
        open my $fh, '<:raw', $path or die "$path: $!";
        local $/;
        return <$fh>;
    }

    my $uc = slurp860('Mediabot/UserCommands.pm');
    my $ka = slurp860('Mediabot/Karma.pm');
    my $mb = slurp860('Mediabot/Mediabot.pm');

    $assert->like($ka, qr/^package Mediabot::Karma;/m,
        'mb676-860: dedicated Karma module exists');

    my @symbols = qw(
        mbKarma_ctx
        processKarma
        mbKarmaHist_ctx
        _karma_current_score
        mbKarmaWatch_ctx
        mbKarmaInfo_ctx
        mbKarmaGraph_ctx
        mbKarmaReset_ctx
        mbKarmaDiff_ctx
        mbKarmaTop_ctx
    );

    for my $name (@symbols) {
        $assert->unlike($uc, qr/^sub \Q$name\E \{/m,
            "mb676-860: $name implementation left UserCommands");
        $assert->like($ka, qr/^sub \Q$name\E \{/m,
            "mb676-860: $name implementation lives in Karma");
        $assert->like($uc, qr/^\s*\Q$name\E\s*$/m,
            "mb676-860: $name remains imported into UserCommands");
    }

    $assert->like($uc, qr/use Mediabot::Karma qw\(/,
        'mb676-860: UserCommands imports Karma compatibility symbols');

    for my $bridge (qw(botPrivmsg botNotice logBot _seconds_to_human)) {
        $assert->like(
            $ka,
            qr/^sub \Q$bridge\E\s+\{\s*goto &Mediabot::UserCommands::\Q$bridge\E\s*\}/m,
            "mb676-860: $bridge compatibility trampoline is explicit"
        );
    }

    for my $export (qw(
        mbKarma_ctx processKarma mbKarmaHist_ctx mbKarmaWatch_ctx mbKarmaInfo_ctx
        mbKarmaGraph_ctx mbKarmaReset_ctx mbKarmaDiff_ctx mbKarmaTop_ctx
    )) {
        $assert->like($uc, qr/^\s*\Q$export\E\s*$/m,
            "mb676-860: historical UserCommands export remains for $export");
    }

    for my $dispatch (qw(
        karma karmatop karmareset karmadiff karmgraph karmawatch karmainfo karmahist
    )) {
        $assert->like($mb, qr/^\s*\Q$dispatch\E\s*=>/m,
            "mb676-860: $dispatch dispatch key remains present");
    }

    $assert->like($ka, qr/INSERT INTO KARMA\b/,
        'mb676-860: primary KARMA write remains with extracted implementation');
    $assert->like($ka, qr/INSERT IGNORE INTO KARMA_LOG\b/,
        'mb676-860: KARMA_LOG persistence remains with extracted implementation');
    $assert->like($ka, qr/check_karma\(/,
        'mb676-860: achievements karma hook remains with extracted implementation');

    my $uc_lines = () = $uc =~ /\n/g;
    $assert->ok($uc_lines < 10300,
        'mb676-860: Karma extraction materially shrinks UserCommands below 10.3k lines');

    require Mediabot::UserCommands;
    require Mediabot::Karma;

    for my $name (@symbols) {
        $assert->ok(Mediabot::Karma->can($name),
            "mb676-860: Mediabot::Karma resolves $name");
        $assert->ok(Mediabot::UserCommands->can($name),
            "mb676-860: historical Mediabot::UserCommands symbol resolves $name");
    }
};
