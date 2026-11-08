use strict;
use warnings;
use utf8;
use Test::More;
use Mediabot::IRC::Presentation qw(_decode_entity _markdown_to_irc format_reply);
my @invalid = ('#65١','#１２','#x110000','#1114112','#xD800','#55296',
    '#x'.('f'x32),'#x'.('f'x1000),'#'.('9'x1000));
for my $entity (@invalid) {
    my (@warnings,$decoded,$rendered);
    {
        local $SIG{__WARN__}=sub {push @warnings,@_};
        $decoded=_decode_entity($entity);
        $rendered=_markdown_to_irc("before &$entity; after");
    }
    is($decoded,"&$entity;",'invalid numeric entity stays literal');
    is($rendered,"before &$entity; after",'renderer retains invalid entity content');
    is_deeply(\@warnings,[],'invalid entity emits no numeric conversion warnings');
}
for my $case (
    ['#65','A'], ['#x41','A'], ['#X1F525','🔥'], ['#1114111',chr(0x10ffff)],
    ['#x10FFFF',chr(0x10ffff)], ['#0',"\0"], ['#x0000',"\0"],
    ['#'.('0'x1000).'65','A'], ['#x'.('0'x1000).'41','A'],
    ['#xD7FF',chr(0xd7ff)], ['#xE000',chr(0xe000)],
    ['amp','&'], ['quot','"'], ['nbsp',' ']
) {
    my ($entity,$want)=@$case;my @warnings;
    my $got;{local $SIG{__WARN__}=sub{push @warnings,@_};$got=_decode_entity($entity)}
    is($got,$want,'valid entity retains decoding semantics');
    is_deeply(\@warnings,[],'valid entity remains warning-free');
}
is_deeply(format_reply('A &#65١; B'),['A &#65١; B'],'public renderer preserves malformed mixed-script decimal');
is_deeply(format_reply('&#65; &#x1F525;'),['A 🔥'],'public renderer decodes valid ASCII numeric entities');
is_deeply(format_reply('`&#65;`'),['&#65;'],'inline code keeps entities literal');
done_testing;
