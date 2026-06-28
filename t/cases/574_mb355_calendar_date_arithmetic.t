# t/cases/574_mb355_calendar_date_arithmetic.t
# mb355 — calendar scheduling must advance calendar dates, not N * 86400 seconds.

use strict;
use warnings;
use Test::More;
use POSIX qw(tzset mktime strftime);
use Time::Local qw(timelocal_posix);

sub slurp {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub extract_sub {
    my ($src, $name) = @_;
    my $start = index($src, "sub $name");
    die "sub $name not found" if $start < 0;
    my $brace = index($src, '{', $start);
    my $depth = 0;
    my ($single, $double, $comment, $escape) = (0, 0, 0, 0);
    for (my $i = $brace; $i < length($src); $i++) {
        my $c = substr($src, $i, 1);
        if ($comment) { $comment = 0 if $c eq "\n"; next }
        if ($single) {
            if ($c eq '\\' && !$escape) { $escape = 1; next }
            $single = 0 if $c eq "'" && !$escape;
            $escape = 0; next;
        }
        if ($double) {
            if ($c eq '\\' && !$escape) { $escape = 1; next }
            $double = 0 if $c eq '"' && !$escape;
            $escape = 0; next;
        }
        if ($c eq '#') { $comment = 1; next }
        if ($c eq "'") { $single = 1; next }
        if ($c eq '"') { $double = 1; next }
        $depth++ if $c eq '{';
        if ($c eq '}') {
            $depth--;
            return substr($src, $start, $i - $start + 1) if $depth == 0;
        }
    }
    die "end of sub $name not found";
}

my $main = slurp('mediabot.pl');
my $helpers = join "\n", map { extract_sub($main, $_) }
    qw(_local_epoch_for_day_offset _next_daily_epoch _next_weekly_epoch);
my $compiled = eval "$helpers\n1;";
ok($compiled, 'calendar helpers compile in isolation') or diag($@);

like($main, qr/use POSIX qw\/setsid strftime mktime\//,
    'main imports POSIX::mktime');
unlike(extract_sub($main, '_local_epoch_for_day_offset'),
    qr/\$now\s*\+\s*\(\$days_ahead\s*\*\s*86400\)/,
    'calendar helper no longer advances dates with fixed seconds');
like(extract_sub($main, '_local_epoch_for_day_offset'),
    qr/\$base\[3\]\s*\+\s*\$days_ahead/,
    'calendar helper advances tm_mday');
like(extract_sub($main, '_local_epoch_for_day_offset'),
    qr/mktime\s*\(/,
    'calendar helper normalises with mktime');
like($main, qr/mb355-B1/, 'mb355 marker is present');

{
    local $ENV{TZ} = 'Europe/Paris';
    tzset();

    my $fall_sunday = timelocal_posix(0, 30, 0, 25, 9, 126);
    my $next_monday = _next_weekly_epoch($fall_sunday, 1, 0, 0);
    is(strftime('%F %T %Z', localtime($next_monday)),
       '2026-10-26 00:00:00 CET',
       'weekly target after fall-back Sunday is the immediate Monday');
    is($next_monday - $fall_sunday, 88200,
       'weekly fall-back delay is the real 24h30 duration');

    my $next_daily = _next_daily_epoch($fall_sunday, 0, 0);
    is(strftime('%F %T %Z', localtime($next_daily)),
       '2026-10-26 00:00:00 CET',
       'daily target after fall-back Sunday uses the next calendar date');

    my $next_sunday = _next_weekly_epoch($fall_sunday, 0, 0, 0);
    is(strftime('%F %T %Z', localtime($next_sunday)),
       '2026-11-01 00:00:00 CET',
       'same-weekday target already passed advances exactly one calendar week');

    my $year_end = timelocal_posix(0, 0, 23, 31, 11, 126);
    my $new_year = _next_daily_epoch($year_end, 0, 0);
    is(strftime('%F %T', localtime($new_year)),
       '2027-01-01 00:00:00',
       'calendar arithmetic crosses the year boundary');

    my $leap_eve = timelocal_posix(0, 0, 23, 28, 1, 124);
    my $leap_day = _next_daily_epoch($leap_eve, 0, 0);
    is(strftime('%F %T', localtime($leap_day)),
       '2024-02-29 00:00:00',
       'calendar arithmetic preserves leap day');
}

tzset();

done_testing();
