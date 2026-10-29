use strict;
use warnings;
use utf8;
use Test::More;
use Encode qw(encode decode FB_CROAK LEAVE_SRC);
use Mediabot::IRC::TextBudget qw(_split_text_for_irc _irc_prefix_for_budget);
use Mediabot::IRC::Output qw(privmsg notice action);
use MB881OutputFixture;

binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';
sub valid_1386 {
    my ($bytes) = @_;
    return eval { decode('UTF-8', $bytes, FB_CROAK | LEAVE_SRC); 1 } ? 1 : 0;
}
{
    my (@actual, @expected);
    for my $budget (16, 391, 400) {
        for my $char ('é', '€', '🙂') {
            my $first = 'x' x ($budget - 1);
            my $last = encode('UTF-8', $char . ('z' x 8));
            my $raw = $first . $last;
            my @chunks = _split_text_for_irc($raw, $budget);
            push @actual, [\@chunks, [map { valid_1386($_) } @chunks],
                [map { utf8::is_utf8($_) ? 1 : 0 } @chunks], $raw];
            push @expected, [[$first, $last], [1,1], [0,0], $first . $last];
        }
    }
    is_deeply(\@actual, \@expected,
        'raw UTF-8 splits before complete two-, three- and four-byte characters, preserving bytes and representation');
}
{
    my (@actual, @expected);
    for my $budget (16, 391, 400) {
        for my $char ('é', '€', '🙂') {
            my $raw = encode('UTF-8', ('x' x ($budget - 1)) . $char . ('z' x 8));
            my $saved = $raw;
            my $prefix = _irc_prefix_for_budget($raw, $budget);
            push @actual, [$prefix, valid_1386($prefix), utf8::is_utf8($prefix) ? 1 : 0, $raw];
            push @expected, [('x' x ($budget - 1)), 1, 0, $saved];
        }
    }
    is_deeply(\@actual, \@expected, 'prefix-only output obeys its byte budget without retaining an incomplete character or consuming input');
}
{
    my (@actual, @expected);
    for my $case (['🙂X',1,''], ['🙂X',3,''], ['🙂X',4,'🙂'],
                  ['éX',1,''], ['éX',2,'é'], ['éX',3,'éX']) {
        my ($text, $budget, $wanted) = @$case;
        my $prefix = _irc_prefix_for_budget(encode('UTF-8', $text), $budget);
        push @actual, [$prefix, valid_1386($prefix), utf8::is_utf8($prefix) ? 1 : 0];
        push @expected, [encode('UTF-8', $wanted), 1, 0];
    }
    is_deeply(\@actual, \@expected, 'tiny byte budgets return no fragment when a whole character cannot fit');
}
MB881OutputFixture::with_policy(sub {
    for my $row ([\&privmsg,'privmsg',400], [\&notice,'notice',400], [\&action,'action',391]) {
        my ($send, $kind, $budget) = @$row;
        my (@actual, @expected);
        my $text = ('x' x ($budget - 1)) . '🙂' . ('z' x 20);
        for my $target ('#test','Nick') {
            for my $input ($text, encode('UTF-8', $text)) {
                my $bot = MB881OutputFixture::new_bot();
                my (@warnings, $error);
                {
                    local $SIG{__WARN__} = sub { push @warnings, @_ };
                    $error = eval { $send->($bot, $target, $input); 1 } ? '' : "$@";
                }
                my @frames = @{$bot->{irc}{wire}};
                my @payloads = map {
                    my $p = $_->{text};
                    $p =~ s/\A\x01ACTION |\x01\z//g if $kind eq 'action';
                    $p;
                } @frames;
                push @actual, [$error, \@warnings, [map { valid_1386($_) } @payloads],
                    [map { utf8::is_utf8($_->{text}) ? 1 : 0 } @frames],
                    [map { length($_->{text}) <= 400 ? 1 : 0 } @frames],
                    [map { $_->{target} } @frames], join('', @payloads),
                    $bot->{metrics}{counts}];
                my $metric = $kind eq 'action' ? {} :
                    {($kind eq 'privmsg' ? 'mediabot_privmsg_out_total' : 'mediabot_notice_out_total') => 2};
                push @expected, ['', [], [1,1], [0,0], [1,1], [$target,$target],
                    encode('UTF-8', $text), $metric];
            }
        }
        is_deeply(\@actual, \@expected, "$kind sends independently valid UTF-8 frames for raw and character input, publicly and privately");
    }
});
{
    my $raw = "\xff" . ('a' x 20);
    my $latin = "\xe9";
    my (@warnings, @chunks, $prefix);
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        @chunks = _split_text_for_irc($raw,16);
        $prefix = _irc_prefix_for_budget($latin,1);
    }
    is_deeply([\@chunks, $prefix, $raw, $latin, \@warnings],
        [["\xff" . ('a' x 15), 'a' x 5], "\xe9", "\xff" . ('a' x 20), "\xe9", []],
        'legacy non-UTF-8 bytes are neither rewritten nor replaced and still produce no warnings');
}
{
    my $text = ('x' x 15) . "é\r\n\0" . ('🙂 café ' x 9);
    my @chars = _split_text_for_irc($text,16);
    my @raw = _split_text_for_irc(encode('UTF-8',$text),16);
    is_deeply([\@raw, [map { valid_1386($_) && !/[\r\n\0]/ ? 1 : 0 } @raw]],
        [[map { encode('UTF-8',$_) } @chars], [(1) x scalar(@chars)]],
        'raw text retains character-path word wrapping and single-line sanitation');
}
done_testing;
