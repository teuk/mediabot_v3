use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use Mediabot::DynamicTemplate qw(normalize_name name_error template_error render_template);
use Encode qw(encode);
use POSIX qw(strftime);

return sub {
    my ($a) = @_;
    for my $name ('café', "cafe\x{301}", 'été_2026', '日本語', 'кофе', 'abc-123', '42', '-old') {
        $a->ok(!name_error($name), "Unicode name accepted: $name");
    }
    $a->is(normalize_name("cafe\x{301}"), 'café', 'decomposed accent normalised to NFC');
    $a->is(normalize_name(encode('UTF-8', 'café')), 'café', 'legacy UTF-8 bytes decoded once');
    for my $name ('', '!café', 'two names', '%n', "a\n", "a\0", '💩', 'a/b', "\x{301}abc", 'a' x 65, "a\xff") {
        $a->ok(name_error($name), 'invalid or oversized name refused');
    }
    $a->ok(!name_error('é' x 64), 'name limit counts Unicode characters');
    $a->ok(!template_error('é' x 244), 'stored action fits Unicode character column');
    $a->like(template_error('é' x 245), qr/244/, 'column overflow rejected');
    for my $text ('', '  ', "bad\rline", "bad\nline", "bad\0line", "\x01ACTION unsafe\x01", "%rand{2,1}", '%rand{0,1000001}', '%rand{-1000001,0}', '%rand{1.5,2}', '%rand{a,b}', '%rand{1,2', '%rand', '%choose{only}', '%choose{a|}', '%choose{ |b}', '%choose{a|{b}}', '%choose{a|b\\q}', '%choose{' . join('|', 1 .. 21) . '}', "bad\xff") {
        $a->ok(template_error($text), "invalid template refused: " . ($text =~ s/[\x00-\x1f]/?/gr));
    }
    my %ctx = (nick => 'Te[u]K', channel => '#café', command => 'bon_café', now => 1700000000);
    $a->is(render_template('fait un café pour %n !', %ctx), 'fait un café pour Te[u]K !', 'original reported coffee command works');
    $a->is(render_template('%n / %N / %nick% / %target% / %args% / %1 / %2', %ctx, args => ['Alice', 'Bob']),
        'Alice Bob / Te[u]K / Te[u]K / Alice / Alice Bob / Alice / Bob', 'caller, target, all and positional args are distinct');
    $a->is(render_template('%args%|%1|%9|%target%', %ctx), '|||Te[u]K', 'missing positions empty, target falls back to caller');
    $a->is(render_template('%s %command% %c %channel%', %ctx), 'bon café bon_café #café #café', 'command and channel names preserve accents');
    $a->is(render_template('%date% %time%', %ctx), strftime('%Y-%m-%d %H:%M', localtime(1700000000)), 'date/time use one clock value');
    $a->is(render_template('%n %N', %ctx, args => ['%rand{1,6}', '%on', '%N']), '%rand{1,6} %on %N Te[u]K', 'inserted arguments never become template instructions');
    $a->is(render_template('%%n %%rand{1,6} 100%% %unknown%', %ctx), '%n %rand{1,6} 100% %unknown%', 'percent escape and unknown named tokens stay literal');
    $a->is(render_template('x  y', %ctx), 'x  y', 'literal spacing preserved');
    $a->is(render_template('%n%N%on%dd%ddd', %ctx, random => sub { 0 }),
        'Te[u]KTe[u]Knon10100', 'adjacent legacy variables remain separate tokens');
    my @sizes;
    my $low = sub { push @sizes, $_[0]; 0 };
    $a->is(render_template('%d! %dd. %ddd, %rand{-2,2} %random{7,7} %choose{thé|café} %choice{a|b} %yesno% %bool% %on %b %B', %ctx, random => $low),
        '1! 10. 100, -2 7 thé a non false non false false', 'random minima, aliases, punctuation and legacy ranges');
    $a->is(join(',', @sizes), '10,90,900,5,1,2,2,2,2,2,2,2', 'draws use inclusive bounded ranges');
    $a->is(render_template('%d %dd %ddd %rand{-2,2} %choose{thé|café} %yesno% %bool%', %ctx, random => sub { $_[0]-1 }),
        '10 99 999 2 café oui true', 'random maxima are reachable');
    my $calls = 0;
    $a->is(render_template('%on/%on %b/%b %B/%B %yesno%/%yesno%', %ctx, random => sub { $calls++ % 2 }),
        'non/non true/true false/false oui/non', 'legacy repeated booleans cached; explicit yesno draws independently');
    $a->is($calls, 5, 'no hidden random draws');
    $a->is(render_template('%choose{a\\|b|c} %choose{\\{literal\\}|other} %choose{%n|x}', %ctx, random => $low),
        'a|b {literal} %n', 'escaped choices and choice values remain literal');
    my $nicks = 0;
    $a->is(render_template('%r %r %R', %ctx, random_nick => sub { 'ami' . ++$nicks }), 'ami1 ami1 ami2', 'legacy random nickname sampling preserved');
    $a->is($nicks, 2, 'nickname fetched lazily and once per legacy token');
    render_template('no random nick', %ctx, random_nick => sub { die 'must not query' });
    $a->is(render_template('%r', %ctx, random_nick => sub { undef }), 'Te[u]K', 'empty channel random nickname falls back to caller');
    for my $bad ("%n", '%choose{a|b}', '%rand{1,6}') {
        my $ok = eval { render_template($bad, %ctx, args => ["bad\nline"], random => sub { -1 }); 1 };
        $a->ok(!$ok, 'invalid context or RNG cannot inject a line or invalid result');
    }
    my $ok = eval { render_template('%n' x 9, %ctx, args => ['x' x 512]); 1 };
    $a->ok(!$ok, 'repeated arguments bounded to 4096 characters');
    for (1 .. 100) {
        my $value = render_template('%rand{-3,8}', %ctx);
        die 'out of range' unless $value =~ /^-?\d+$/ && $value >= -3 && $value <= 8;
    }
    $a->pass('production random generator stays within bounds');
};
