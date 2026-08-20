# t/cases/848_mb666_channel_awards.t
# =============================================================================
# mb666 — bounded cross-feature Channel Awards.
# =============================================================================
use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

{
    package AChan848;
    sub new { bless { id => $_[1] }, $_[0] }
    sub get_id { $_[0]{id} }

    package ASTH848;
    sub new { bless { kind => $_[1], rows => [], i => 0 }, $_[0] }
    sub execute {
        my ($s, @bind) = @_;
        $s->{i} = 0;
        if ($s->{kind} eq 'karma') {
            my $role = $bind[0] // 'received';
            $s->{rows} = $role eq 'given'
                ? [ { who=>'dave',  positive_count=>22 } ]
                : [ { who=>'carol', positive_count=>18 } ];
        }
        elsif ($s->{kind} eq 'community') {
            $s->{rows} = [ {
                archivist  => "eve\t9",
                lorekeeper => "frank\t6",
            } ];
        }
        return 1;
    }
    sub fetchrow_hashref {
        my ($s) = @_;
        return undef if $s->{i} >= @{ $s->{rows} };
        return $s->{rows}[ $s->{i}++ ];
    }
    sub finish { 1 }

    package ADBH848;
    sub new { bless { sql => [] }, shift }
    sub prepare {
        my ($s, $sql) = @_;
        push @{ $s->{sql} }, $sql;
        return ASTH848->new('karma')     if $sql =~ /\bFROM KARMA_LOG\b/s;
        return ASTH848->new('community') if $sql =~ /\bFROM QUOTES\b.*\bFROM FACTOID\b/s;
        die "mb666-848 unexpected SQL: $sql";
    }

    package ACtx848;
    sub new { bless $_[1], $_[0] }
    sub bot { $_[0]{bot} }
    sub nick { $_[0]{nick} }
    sub channel { $_[0]{channel} }
    sub args { $_[0]{args} }
}

sub slurp848 {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

sub extract_sub848 {
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
    my $expected_days = 7;
    my $gather_calls = 0;
    my $dbh = ADBH848->new;
    my $bot = bless {
        dbh => $dbh,
        channels => { '#teuk' => AChan848->new(42) },
    }, 'Mediabot';
    my $ctx = ACtx848->new({
        bot=>$bot, nick=>'tester', channel=>'#teuk', args=>[],
    });

    no warnings 'redefine';
    no warnings 'once';
    local *Mediabot::UserCommands::botPrivmsg = sub { push @sent, $_[2]; 1 };
    local *Mediabot::UserCommands::botNotice  = sub { push @sent, "NOTICE: $_[2]"; 1 };
    local *Mediabot::Helpers::channel_log_gather = sub {
        my ($self, $dbh2, $sql, $bind, $cb, $scope) = @_;
        $gather_calls++;
        $assert->is($scope, 'content', 'mb666-848: awards uses archive-aware content scope');
        $assert->like($sql, qr/INTERVAL \Q$expected_days\E DAY/,
            "mb666-848: history window is bounded to ${expected_days}d");
        $assert->like($sql, qr/HOUR\(cl\.ts\) BETWEEN 0 AND 5/,
            'mb666-848: Night Owl reuses the 00:00-05:59 band');
        $cb->({ nick=>'Alice', msg_count=>120, night_count=>5 }, 'CHANNEL_LOG');
        $cb->({ nick=>'alice', msg_count=>20,  night_count=>3 }, 'archive.CHANNEL_LOG_ARCHIVE');
        $cb->({ nick=>'Bob',   msg_count=>80,  night_count=>40 }, 'CHANNEL_LOG');
        return { live_ok=>1, rows=>3 };
    };

    my $ok = eval { Mediabot::UserCommands::mbAwards_ctx($ctx); 1 };
    $assert->ok($ok, 'mb666-848: awards executes on mocked bounded data');

    my $out = join("\n", @sent);
    $assert->like($out, qr/#teuk Awards.*last 7 days/s,
        'mb666-848: output has compact period header');
    $assert->like($out, qr/Top Voice:.*Alice.*140 msgs/s,
        'mb666-848: live/archive nick variants merge for Top Voice');
    $assert->like($out, qr/Night Owl:.*Bob.*40 night msgs/s,
        'mb666-848: Night Owl winner uses night-only count');
    $assert->like($out, qr/Karma Magnet:.*carol.*18 positive votes/s,
        'mb666-848: positive karma receiver is surfaced');
    $assert->like($out, qr/Generous Soul:.*dave.*22 positive votes/s,
        'mb666-848: positive karma giver is surfaced');
    $assert->like($out, qr/Archivist:.*eve.*9 quotes/s,
        'mb666-848: recent quote contributor is surfaced');
    $assert->like($out, qr/Lorekeeper:.*frank.*6 factoids/s,
        'mb666-848: recent factoid contributor is surfaced');
    $assert->ok(scalar(@sent) <= 4,
        'mb666-848: awards output is bounded to header plus three lines');
    $assert->is($gather_calls, 1,
        'mb666-848: default execution performs one history gather');
    for my $sql (@{ $dbh->{sql} }) {
        $assert->like($sql, qr/INTERVAL 7 DAY/,
            'mb666-848: default secondary query is bounded to 7d');
    }

    # Exercise the second supported public window, including every secondary
    # source. This catches a branch that a source-only assertion cannot prove.
    @sent = ();
    $expected_days = 30;
    $ctx->{args} = [ '30d' ];
    my $sql_before_30 = scalar @{ $dbh->{sql} };
    my $ok30 = eval { Mediabot::UserCommands::mbAwards_ctx($ctx); 1 };
    $assert->ok($ok30, 'mb666-848: explicit 30d window executes');
    my $out30 = join("\n", @sent);
    $assert->like($out30, qr/#teuk Awards.*last 30 days/s,
        'mb666-848: 30d runtime header is correct');
    my @sql30 = @{ $dbh->{sql} }[$sql_before_30 .. $#{ $dbh->{sql} }];
    $assert->is(scalar(@sql30), 2,
        'mb666-848: 30d execution still owns exactly two secondary reads');
    for my $sql (@sql30) {
        $assert->like($sql, qr/INTERVAL 30 DAY/,
            'mb666-848: 30d secondary query is bounded to 30d');
    }

    # Reject every unreviewed period before any database work begins.
    @sent = ();
    $ctx->{args} = [ '14d' ];
    my $gathers_before_bad = $gather_calls;
    my $sql_before_bad = scalar @{ $dbh->{sql} };
    my $ok_bad = eval { Mediabot::UserCommands::mbAwards_ctx($ctx); 1 };
    $assert->ok($ok_bad, 'mb666-848: invalid period is handled without exception');
    $assert->like(join("\n", @sent), qr/^NOTICE: Syntax: awards \[7d\|30d\]$/m,
        'mb666-848: invalid period returns the strict syntax');
    $assert->is($gather_calls, $gathers_before_bad,
        'mb666-848: invalid period performs no history gather');
    $assert->is(scalar @{ $dbh->{sql} }, $sql_before_bad,
        'mb666-848: invalid period performs no secondary query');

    my $uc = slurp848('Mediabot/SocialHistory.pm');
    my $mb = slurp848('Mediabot/Mediabot.pm');
    my $hp = slurp848('Mediabot/Helpers.pm');

    my $awards_src = extract_sub848($uc, 'mbAwards_ctx');
    $assert->ok(defined($awards_src) && length($awards_src),
        'mb666-848: awards source extraction is structural, not whitespace-sensitive');
    $awards_src //= '';
    $assert->unlike($awards_src, qr/ORDER\s+BY\s+RAND\s*\(/i,
        'mb666-848: awards adds no ORDER BY RAND()');
    $assert->unlike($awards_src, qr/\bUNION\s+ALL\b/i,
        'mb666-848: awards preserves the per-table no-UNION-ALL archive contract');
    my $gathers = () = $awards_src =~ /channel_log_gather\(/g;
    my $prepares = () = $awards_src =~ /\$dbh->prepare\(/g;
    $assert->is($gathers, 1,
        'mb666-848: awards owns exactly one archive-aware history gather');
    $assert->is($prepares, 2,
        'mb666-848: awards owns exactly two secondary prepares (karma + community)');
    $assert->ok(index($awards_src, q{$period !~ /\A(?:7d|30d)\z/}) >= 0,
        'mb666-848: awards accepts only the reviewed 7d/30d windows');
    $assert->like($mb,
        qr/awards\s*=>\s*sub\s*\{\s*Mediabot::CommandAsync::run_ctx_async\(\$ctx->bot,\s*\$ctx,\s*'awards'/s,
        'mb666-848: public awards dispatch uses CommandAsync');
    $assert->like($mb, qr/^awards\|awards \[7d\|30d\]\|public\|/m,
        'mb666-848: public help documents the strict period contract');
    $assert->like($hp, qr/^\s*awards\s*=>\s*20,/m,
        'mb666-848: 20s cooldown lives in the parent-side generic guard');
};
