use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

sub _slurp_mb387 {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot open $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_mb387 {
    my ($src, $start, $next) = @_;
    return $1 if $src =~ /(sub\s+\Q$start\E\s*\{.*?)(?=\nsub\s+\Q$next\E\s*\{)/s;
    return;
}

my $case = sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');
    my $file = File::Spec->catfile($root, 'Mediabot', 'Helpers.pm');
    my $src = _slurp_mb387($file);

    my $privmsg = _extract_mb387($src, 'botPrivmsg', 'botAction');
    my $action  = _extract_mb387($src, 'botAction', 'botNotice');

    $assert->(defined $privmsg, 'botPrivmsg body extracted');
    $assert->(defined $action,  'botAction body extracted');
    return unless defined $privmsg && defined $action;

    for my $entry (
        [ botPrivmsg => $privmsg ],
        [ botAction  => $action  ],
    ) {
        my ($name, $body) = @$entry;

        my $badword_pos = index($body, 'for my $bw');
        my $history_pos = rindex($body, 'logBotAction');
        my $live_pos    = index($body, '[LIVE]');
        my $wire_pos    = index($body, 'do_PRIVMSG');

        $assert->($badword_pos >= 0, "$name still checks badwords");
        $assert->($history_pos >= 0, "$name still records accepted channel history");
        $assert->($live_pos >= 0, "$name still emits a LIVE log for accepted output");
        $assert->($wire_pos >= 0, "$name still sends accepted output to IRC");
        $assert->($live_pos > $badword_pos,
            "$name writes LIVE only after the badword guard");
        $assert->($live_pos > $history_pos,
            "$name writes LIVE only after accepted history is recorded");
        $assert->($live_pos < $wire_pos,
            "$name writes LIVE immediately before the wire phase");
        my $live_count = () = $body =~ /\[LIVE\]/g;
        $assert->($live_count == 1,
            "$name contains exactly one LIVE log site");

        my $blocked = '';
        if ($body =~ /(if \(index\([^\n]+\).*?return;)/s) {
            $blocked = $1;
        }
        $assert->($blocked ne '', "$name blocked-badword branch extracted");
        $assert->($blocked !~ /\[LIVE\]/,
            "$name blocked-badword branch cannot claim LIVE delivery");
        $assert->($blocked !~ /logBotAction/,
            "$name blocked-badword branch does not enter conversation history");
        my $keeps_diagnostics =
            ($blocked =~ /noticeConsoleChan/) && ($blocked =~ /logger\}->log\(3/);
        $assert->($keeps_diagnostics,
            "$name preserves explicit operational block diagnostics");
    }

    $assert->($src =~ /mb387-B1/, 'MB387 source marker is present');
};

if (caller) { return $case; }

my ($tests, $fail) = (0, 0);
my $assert = sub {
    my ($ok, $name) = @_;
    $tests++;
    $name = 'unnamed assertion' unless defined $name && $name ne '';
    if ($ok) { print "ok $tests - $name\n"; }
    else { print "not ok $tests - $name\n"; $fail++; }
};

$case->($assert);
print "1..$tests\n";
exit($fail ? 1 : 0);
