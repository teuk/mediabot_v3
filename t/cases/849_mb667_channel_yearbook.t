# t/cases/849_mb667_channel_yearbook.t
# =============================================================================
# mb667 — archive-aware annual Channel Yearbook.
# =============================================================================
use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

{
    package YChan849;
    sub new { bless { id => $_[1] }, $_[0] }
    sub get_id { $_[0]{id} }

    package YSTH849;
    sub new { bless { rows => [], i => 0, bind => [] }, $_[0] }
    sub execute {
        my ($s, @bind) = @_;
        $s->{bind} = [@bind];
        $s->{i} = 0;
        $s->{rows} = [ { quote_count => 2, factoid_count => 1 } ];
        return 1;
    }
    sub fetchrow_hashref {
        my ($s) = @_;
        return undef if $s->{i} >= @{ $s->{rows} };
        return $s->{rows}[ $s->{i}++ ];
    }
    sub finish { 1 }

    package YDBH849;
    sub new { bless { sql => [], sth => [] }, shift }
    sub prepare {
        my ($s, $sql) = @_;
        push @{ $s->{sql} }, $sql;
        my $sth = YSTH849->new;
        push @{ $s->{sth} }, $sth;
        return $sth if $sql =~ /\bFROM QUOTES\b.*\bFROM FACTOID\b/s;
        die "mb667-849 unexpected SQL: $sql";
    }

    package YCtx849;
    sub new { bless $_[1], $_[0] }
    sub bot { $_[0]{bot} }
    sub nick { $_[0]{nick} }
    sub channel { $_[0]{channel} }
    sub args { $_[0]{args} }
}

sub slurp849 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

sub extract_sub849 {
    my ($src, $sub_name) = @_;

    my $re = qr/^[ \t]*sub[ \t]+\Q$sub_name\E\b[^{]*\{/m;
    return undef unless $src =~ /$re/g;

    my $start = $-[0];
    my $pos   = pos($src);
    my $depth = 1;
    my $len   = length($src);
    my ($quote, $escape, $comment);

    while ($pos < $len) {
        my $ch = substr($src, $pos, 1);
        if ($comment) {
            $comment = 0 if $ch eq "\n";
            $pos++;
            next;
        }
        if (defined $quote) {
            if ($escape) { $escape = 0; $pos++; next; }
            if ($ch eq "\\") { $escape = 1; $pos++; next; }
            if ($ch eq $quote) { undef $quote; $pos++; next; }
            $pos++;
            next;
        }
        if ($ch eq '#') { $comment = 1; $pos++; next; }
        if ($ch eq '"' || $ch eq "'") { $quote = $ch; $pos++; next; }
        if ($ch eq '{') { $depth++; }
        elsif ($ch eq '}') {
            $depth--;
            return substr($src, $start, $pos + 1 - $start) if $depth == 0;
        }
        $pos++;
    }
    return undef;
}

return sub {
    my ($assert) = @_;

    require Mediabot::UserCommands;

    my @sent;
    my $expected_year = (localtime())[5] + 1899; # last completed year
    my $gather_calls = 0;
    my $dbh = YDBH849->new;
    my $bot = bless {
        dbh => $dbh,
        channels => { '#teuk' => YChan849->new(42) },
    }, 'Mediabot';
    my $ctx = YCtx849->new({
        bot=>$bot, nick=>'tester', channel=>'#teuk', args=>[],
    });

    no warnings 'redefine';
    no warnings 'once';
    local *Mediabot::UserCommands::botPrivmsg = sub { push @sent, $_[2]; 1 };
    local *Mediabot::UserCommands::botNotice  = sub { push @sent, "NOTICE: $_[2]"; 1 };
    local *Mediabot::Helpers::chanset_enabled = sub { 1 };
    local *Mediabot::Helpers::channel_log_gather = sub {
        my ($self, $dbh2, $sql, $bind, $cb, $scope) = @_;
        $gather_calls++;
        $assert->is($scope, 'content',
            'mb667-849: yearbook uses archive-aware content scope');
        $assert->is($bind->[0], 42,
            'mb667-849: yearbook binds the current channel id');
        $assert->is($bind->[1], "$expected_year-01-01 00:00:00",
            'mb667-849: annual window starts at Jan 1');
        $assert->is($bind->[2], ($expected_year + 1) . '-01-01 00:00:00',
            'mb667-849: annual window ends at next Jan 1');

        if ($sql =~ /GROUP BY nick/) {
            $cb->({ nick=>'Alice', messages=>500 }, 'CHANNEL_LOG');
            $cb->({ nick=>'alice', messages=>300 }, 'archives.CHANNEL_LOG_ARCHIVE');
            $cb->({ nick=>'Bob',   messages=>500 }, 'CHANNEL_LOG');
            $cb->({ nick=>'Carol', messages=>400 }, 'archives.CHANNEL_LOG_ARCHIVE');
        }
        elsif ($sql =~ /GROUP BY DATE\(ts\), HOUR\(ts\)/) {
            $cb->({ day_key=>"$expected_year-12-26", hour_key=>16, messages=>600 }, 'CHANNEL_LOG');
            $cb->({ day_key=>"$expected_year-12-27", hour_key=>17, messages=>400 }, 'CHANNEL_LOG');
            $cb->({ day_key=>"$expected_year-12-26", hour_key=>16, messages=>400 }, 'archives.CHANNEL_LOG_ARCHIVE');
            $cb->({ day_key=>"$expected_year-01-22", hour_key=>16, messages=>300 }, 'archives.CHANNEL_LOG_ARCHIVE');
        }
        else {
            die "mb667-849 unexpected gather SQL: $sql";
        }
        return { live_ok=>1, tainted=>0, rows=>4 };
    };

    my $ok = eval { Mediabot::UserCommands::mbYearbook_ctx($ctx); 1 };
    $assert->ok($ok, 'mb667-849: default yearbook executes on merged live/archive data');

    my $out = join("\n", @sent);
    $assert->like($out, qr/#teuk Yearbook.*\Q$expected_year\E/s,
        'mb667-849: default is the last completed calendar year');
    $assert->like($out, qr/1\.7k msgs.*3 voices.*busiest month: Dec \(1\.4k\)/s,
        'mb667-849: annual totals and busiest month are rendered');
    $assert->like($out, qr/peak day: Dec 26 \(1\.0k msgs\).*16:00-17:00 \(1\.3k msgs\)/s,
        'mb667-849: live/archive day and hour buckets merge correctly');
    $assert->like($out, qr/top voices:.*Alice.*800.*Bob.*500.*Carol.*400/s,
        'mb667-849: case-only nick variants merge in the annual top voices');
    $assert->like($out, qr/2 quotes added.*1 factoids learned/s,
        'mb667-849: annual community contributions are included');
    $assert->like($out, qr/recorded Jan 22-Dec 27/s,
        'mb667-849: observed activity span is disclosed without claiming missing data');
    $assert->is(scalar(@sent), 5,
        'mb667-849: yearbook output is bounded to five IRC lines');
    $assert->is($gather_calls, 2,
        'mb667-849: yearbook owns exactly two archive-aware history gathers');
    $assert->is(scalar @{ $dbh->{sql} }, 1,
        'mb667-849: yearbook owns one direct community read');

    my $sth = $dbh->{sth}[0];
    $assert->is($sth->{bind}[0], 42,
        'mb667-849: quote contribution query is channel-scoped');
    $assert->is($sth->{bind}[1], "$expected_year-01-01 00:00:00",
        'mb667-849: quote contribution query is year-scoped');
    $assert->is($sth->{bind}[3], 42,
        'mb667-849: factoid contribution query is channel-scoped');

    # Future years are rejected before any DB/history work.
    @sent = ();
    my $current_year = (localtime())[5] + 1900;
    $ctx->{args} = [ $current_year + 1 ];
    my $g_before = $gather_calls;
    my $q_before = scalar @{ $dbh->{sql} };
    my $bad_ok = eval { Mediabot::UserCommands::mbYearbook_ctx($ctx); 1 };
    $assert->ok($bad_ok, 'mb667-849: future year is handled without exception');
    $assert->like(join("\n", @sent), qr/^NOTICE: Syntax: yearbook \[YYYY\]/m,
        'mb667-849: future year returns strict syntax');
    $assert->is($gather_calls, $g_before,
        'mb667-849: invalid year performs no history gather');
    $assert->is(scalar @{ $dbh->{sql} }, $q_before,
        'mb667-849: invalid year performs no direct query');

    my $uc = slurp849('Mediabot/SocialHistory.pm');
    my $mb = slurp849('Mediabot/Mediabot.pm');
    my $hp = slurp849('Mediabot/Helpers.pm');
    my $yb_src = extract_sub849($uc, 'mbYearbook_ctx') // '';
    my $collect_src = extract_sub849($uc, '_yearbook_collect') // '';

    $assert->ok(length($yb_src) && length($collect_src),
        'mb667-849: yearbook source extraction is structural');
    $assert->unlike($collect_src, qr/ORDER\s+BY\s+RAND\s*\(/i,
        'mb667-849: yearbook adds no ORDER BY RAND()');
    my $gathers = () = $collect_src =~ /channel_log_gather\(/g;
    my $prepares = () = $collect_src =~ /\$dbh->prepare\(/g;
    $assert->is($gathers, 2,
        'mb667-849: implementation owns exactly two history gathers');
    $assert->is($prepares, 1,
        'mb667-849: implementation owns exactly one secondary prepare');
    $assert->like($collect_src, qr/GROUP BY DATE\(ts\), HOUR\(ts\)/,
        'mb667-849: one bounded day/hour cube feeds month, day and hour peaks');
    $assert->like($yb_src, qr/\$current_year\s*-\s*1/,
        'mb667-849: no-argument default is the last completed year');
    $assert->like($yb_src, qr/chanset_enabled\([^;]+['"]OnThisDay['"]/s,
        'mb667-849: yearbook reuses the existing channel-history opt-out');
    $assert->like($mb,
        qr/yearbook\s*=>\s*sub\s*\{\s*Mediabot::CommandAsync::run_ctx_async\(\$ctx->bot,\s*\$ctx,\s*'yearbook'/s,
        'mb667-849: public yearbook dispatch uses CommandAsync');
    $assert->like($mb, qr/^yearbook\|yearbook \[YYYY\]\|public\|/m,
        'mb667-849: help documents the annual contract');
    $assert->like($hp, qr/^\s*yearbook\s*=>\s*60,/m,
        'mb667-849: 60s cooldown lives in the parent-side generic guard');
};
