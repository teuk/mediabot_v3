use strict;
use warnings;
use utf8;
use Test::More;
use Mediabot::Hailo::Normalizer qw(rehydrate_hailo_output normalize_hailo_input);
use Mediabot::Hailo::PostEditor ();
use Mediabot::Hailo::PostEditRuntime ();

for my $digits ('٠١', '１２', '१२', '𝟙𝟚', '0١', '１0') {
    my $token = "zzhailonick${digits}zz";
    my @warnings;
    my $out;
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        $out = rehydrate_hailo_output(channel => '#test', speaker => 'Alice',
            text => "Hello $token today", bucket_nicks => {zzhailonick00zz => ['Bob'], $token => ['Carol']});
    }
    ok($out->{ok}, 'literal Unicode token-like text is accepted');
    is($out->{line}, "Hello $token today", 'non-ASCII token is not converted to another nickname');
    is_deeply(\@warnings, [], 'no numeric conversion warnings');
}
for my $bucket (0 .. 31) {
    my $token = sprintf('zzhailonick%02dzz', $bucket);
    my $out = rehydrate_hailo_output(channel => '#test',
        text => "Hello $token today", bucket_nicks => {$token => ['Bob']});
    is($out->{line}, 'Hello Bob today', 'valid ASCII bucket restores its nickname');
    $out = rehydrate_hailo_output(channel => '#test', speaker => 'Alice', text => "Hello $token today");
    is($out->{line}, 'Hello Alice today', 'valid ASCII bucket retains speaker fallback');
}

# IRC colour parameters contain ASCII digits only; Unicode numbers are text.
{
    my @warnings;
    local $SIG{__WARN__}=sub {push @warnings,@_};
    my @cases=(
        ["\x0304,12bonjour",'bonjour'],
        ["\x0304bonjour",'bonjour'],
        ["\x03bonjour",'bonjour'],
        ["\x030412bonjour",'12bonjour'],
    );
    for my $digits ('١٢','１２','१२','𝟙𝟚') {
        push @cases,
            ["\x03${digits} pommes","${digits} pommes"],
            ["\x0304,${digits} pommes",",${digits} pommes"],
            ["\x030${digits} pommes","${digits} pommes"];
    }
    for my $case (@cases) {
        my ($text,$expected)=@$case;
        is(normalize_hailo_input(channel=>'#test',text=>$text)->{text},$expected,
            'learning input removes only ASCII colour parameters');
        is(rehydrate_hailo_output(channel=>'#test',text=>$text)->{line},$expected,
            'brain output preserves Unicode numbers beside colour controls');
        is(Mediabot::Hailo::PostEditor::_clean_provider_line($text,700),$expected,
            'provider sanitization preserves the same literal number');
        is(Mediabot::Hailo::PostEditRuntime::_clean_context_line($text,700),$expected,
            'context and final emission sanitization preserve the same number');
    }
    is_deeply(\@warnings,[],'colour cleanup stays warning-free');
}

done_testing;
