# t/cases/393_mb134_botaction_badword_cache.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

my $case = sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');
    my $helpers_file = File::Spec->catfile($root, 'Mediabot', 'Helpers.pm');

    open my $hfh, '<', $helpers_file
        or do { $assert->(0, "cannot open Helpers.pm: $!"); return; };
    my $src = do { local $/; <$hfh> };
    close $hfh;

    my $block = ($src =~ /sub botAction \{(.*?)sub botNotice \{/s) ? $1 : '';

    $assert->($block ne '', 'botAction block extracted');
    $assert->($block =~ /mb134-B8: keep botAction aligned with botPrivmsg/,
        'botAction contains mb134-B8 marker');
    $assert->($block =~ /\$self->\{_badword_cache\}\{\$sTo\}/,
        'botAction uses _badword_cache keyed by channel');
    $assert->($block =~ /my \$ttl\s+=\s+300/,
        'botAction badword cache TTL is 300 seconds');
    $assert->($block =~ /SELECT badword FROM CHANNEL JOIN BADWORDS/,
        'botAction still loads channel badwords when cache is stale');
    $assert->($block =~ /\$sth->finish;/,
        'botAction finishes SQL handle on successful cache load');
    $assert->($block =~ /\$sth->finish if \$sth;/,
        'botAction finishes SQL handle defensively on SQL error');
    $assert->($block =~ /mediabot_db_query_errors_total/,
        'botAction increments DB error metric on badword SQL failure');
    $assert->($block =~ /for my \$bw \(\@\{ \$cache->\{words\} \/\/ \[\] \}\)/,
        'botAction checks cached badwords');

    $assert->($block !~ /my \$sQuery = "SELECT badword FROM CHANNEL JOIN BADWORDS.*?unless \(\$sth && \$sth->execute\(\$sTo\).*?while \(my \$ref = \$sth->fetchrow_hashref\(\)\).*?logBotAction\(\$self,undef,\$eventtype,\$self->\{irc\}->nick_folded,\$sTo,\$sMsg\);/s,
        'old direct per-ACTION SQL badword path is gone');

    $assert->(index($block, '$self->{_badword_cache}{$sTo} =') >= 0,
        'botAction stores loaded badwords in _badword_cache');

    $assert->(index($block, 'words => \\@words') >= 0,
        'botAction stores badword list as arrayref');
};

if (caller) { return $case; }

my $tests = 0;
my $fail  = 0;

my $assert = sub {
    my ($ok, $name) = @_;
    $tests++;
    $name = 'unnamed assertion' unless defined $name && $name ne '';

    if ($ok) {
        print "ok $tests - $name\n";
    }
    else {
        print "not ok $tests - $name\n";
        $fail++;
    }
};

$case->($assert);
print "1..$tests\n";
exit($fail ? 1 : 0);
