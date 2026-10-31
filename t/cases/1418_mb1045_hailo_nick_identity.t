use strict;
use warnings;
use utf8;
use Test::More;
use Mediabot::Hailo::Normalizer qw(
    normalize_hailo_input rehydrate_hailo_output hailo_placeholder_for_nick
);

my @warnings;
local $SIG{__WARN__}=sub {push @warnings,@_};
sub input_1418 {
    my ($text,%opts)=@_;
    return normalize_hailo_input(channel=>'#Salon',speaker=>'Alice',bot_nick=>'Media[bot]',
        nicks=>['Alice','Media[bot]',$opts{peer}//'Te[u]K'],text=>$text,%opts);
}
sub output_1418 {
    my ($text,%opts)=@_;
    return rehydrate_hailo_output(channel=>'#Salon',speaker=>'Alice',bot_nick=>'Media[bot]',
        nicks=>['Alice','Media[bot]',$opts{peer}//'Te[u]K'],text=>$text,%opts);
}
for my $pair (['Te[u]K','TE{U}K'],['Jean\\Luc','JEAN|LUC'],['Nick^','NICK~']) {
    my ($visible,$variant)=@$pair;
    my $token=hailo_placeholder_for_nick(channel=>'#Salon',nick=>$visible);
    my $r=input_1418("salut $variant !",peer=>$visible);
    is_deeply([@$r{qw(ok text target_nick)}],[1,"salut $token !",$visible],
        "$visible: equivalent IRC spelling becomes the same neutral learned identity");
    my $out=output_1418("salut $variant !",peer=>$visible);
    is_deeply([@$out{qw(ok line)}],[1,"salut $visible !"],
        "$visible: output restores the current visible spelling");
}
{
    my $r=input_1418('salut TE{U}K et Media{bot} !',speaker=>'Te[u]K');
    is_deeply([@$r{qw(ok text target_nick)}],
        [1,'salut zzhailospeakerzz et zzhailoselfzz !','Media[bot]'],
        'speaker and bot aliases keep their dedicated identities and target semantics');
}
for my $text ('TE{U}K: bonjour tout le monde','@TE{U}K | bonjour tout le monde',
        '[12:34] <Alice> MEDIA{BOT}: bonjour tout le monde') {
    my $r=input_1418($text);
    is_deeply([@$r{qw(ok text)}],[1,'bonjour tout le monde'],
        'equivalent nickname prefixes are stripped by the existing copied-line normalization');
}
{
    my $r=input_1418('@MEDIA{BOT} bonjour tout le monde');
    is_deeply([@$r{qw(ok text)}],[1,'bonjour tout le monde'],
        'leading bot address without copied-line punctuation uses the same IRC identity');
}
{
    my $r=input_1418('Media{bot}: !kick TE{U}K',command_prefixes=>['!','.']);
    ok($r->{ok} && $r->{is_command},
        'removing an equivalent bot address still classifies the following command before learning');
}
{
    my $r=input_1418('salut Te[u]K TE{U}K',nicks=>['Alice','Media[bot]','Te[u]K','TE{U}K']);
    my $token=hailo_placeholder_for_nick(channel=>'#Salon',nick=>'Te[u]K');
    is_deeply([$r->{text},$r->{bucket_nicks}{$token}],
        ["salut $token $token",['Te[u]K']],
        'fold-equivalent nicklist entries remain deduplicated while both text spellings are normalized');
}
{
    my $r=input_1418('hello x a?b Med[bot',peer=>'bot|x',bot_nick=>'MainBot',
        nicks=>['Alice','MainBot','bot|x','a.b','Med[other']);
    is_deeply([@$r{qw(ok text target_nick)}],[1,'hello x a?b Med[bot',undef],
        'regex metacharacters stay escaped instead of becoming alternation, wildcards or invalid patterns');
}
{
    my $r=input_1418('preTE{U}K TE{U}Kpost _TE{U}K TE{U}K_ 7TE{U}K TE{U}K9');
    is($r->{text},'preTE{U}K TE{U}Kpost _TE{U}K TE{U}K_ 7TE{U}K TE{U}K9',
        'letter, digit and underscore boundaries continue protecting larger words');
}
{
    my $r=input_1418('bonjour zoé et BOB',peer=>'Zoé',nicks=>['Alice','Media[bot]','Zoé','Bob']);
    my $zoe=hailo_placeholder_for_nick(channel=>'#Salon',nick=>'Zoé');
    my $bob=hailo_placeholder_for_nick(channel=>'#Salon',nick=>'Bob');
    is($r->{text},"bonjour $zoe et $bob",'ordinary Unicode and ASCII case-insensitive mentions remain compatible');
}
{
    my $r=output_1418('zzhailoselfzz parle à zzhailospeakerzz et TE{U}K');
    is($r->{line},'Alice parle à Alice et Te[u]K',
        'existing nick-switch placeholders and visible-name restoration still compose');
}
{
    my @pairs=(['Te[u]K','TE{U}K'],['Jean\\Luc','JEAN|LUC'],['Nick^','NICK~']);
    ok(!grep({hailo_placeholder_for_nick(channel=>'#Salon',nick=>$_->[0])
        ne hailo_placeholder_for_nick(channel=>'#Salon',nick=>$_->[1])} @pairs),
        'existing persistent bucket identities are preserved for equivalent spellings');
}
{
    my $r=output_1418('!kick TE{U}K');
    is($r->{reason},'command_output','output command rejection remains active after nickname restoration');
}
is_deeply(\@warnings,[],'normalization, prefix stripping and rehydration remain warning-free');
done_testing;
