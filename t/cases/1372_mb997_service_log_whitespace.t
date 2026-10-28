use strict;
use warnings;
use utf8;
use Test::More;
use Mediabot::IRC::Text qw(redact_service_secret);
use Mediabot::IRC::Output ();
use Mediabot::Helpers ();
binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';
my @warnings;
local $SIG{__WARN__} = sub { push @warnings, @_ };
my $token = join('-', qw(example only marker));
for my $case (
    ["  identify $token", 'identify ****'],
    ["\tID account $token", 'ID account ****'],
    [" \tlogin account $token", 'login account ****'],
    ["\x{a0}AUTH\x{a0}account\x{a0}$token", 'AUTH account ****'],
    ["  ghost Nick $token", 'ghost Nick ****'],
    [" recover Nick $token", 'recover Nick ****'],
    [" release Nick $token", 'release Nick ****'],
    [" register $token account\@example.invalid", 'register **** account@example.invalid'],
    [" set\tpassword $token", 'set password ****'],
) {
    my ($input,$expected) = @$case;
    my $original = $input;
    is_deeply([redact_service_secret($input),
               Mediabot::Helpers::_redact_irc_service_secret_for_log($input), $input],
        [$expected,$expected,$original],
        'leading whitespace cannot bypass masking and the caller scalar is preserved');
}
my @ordinary = (undef, '', " \t ", "  loginish $token", "hello identify $token", ' ordinary text', '0');
is_deeply([map { redact_service_secret($_) } @ordinary], \@ordinary,
    'undefined, empty, ordinary and near-keyword text retain their original whitespace');
{
    package MB997::Logger;
    sub log { push @{$_[0]{entries}}, [@_[1,2]]; 1 }
    package MB997::IRC;
    sub do_PRIVMSG { my ($s,%a)=@_; push @{$s->{wire}}, ['PRIVMSG',\%a]; 1 }
    sub do_NOTICE { my ($s,%a)=@_; push @{$s->{wire}}, ['NOTICE',\%a]; 1 }
}
for my $kind (qw(privmsg action notice)) {
    my $logger = bless {entries=>[]}, 'MB997::Logger';
    my $irc = bless {wire=>[]}, 'MB997::IRC';
    my $bot = {logger=>$logger,irc=>$irc};
    # The token falls in a later wire chunk. All values are test fixtures.
    my $input = "\t  login " . ('a' x 405) . " $token";
    my $original = $input;
    Mediabot::IRC::Output->can($kind)->($bot,'NickServ',$input);
    my $logs = join("\n", map { $_->[1] } @{$logger->{entries}});
    is_deeply([index($logs,$token) >= 0 ? 1 : 0, index($logs,'****') >= 0 ? 1 : 0],
        [0,1], "$kind masks the fixture token in every normal/debug log");
    my @payload;
    my $bounded = 1;
    my $correct_envelope = 1;
    for my $row (@{$irc->{wire}}) {
        my ($verb,$data) = @$row;
        $bounded = 0 if length($data->{text}) > 400;
        $correct_envelope = 0 unless $verb eq ($kind eq 'notice' ? 'NOTICE' : 'PRIVMSG')
            && $data->{target} eq 'NickServ';
        my $body = $data->{text};
        if ($kind eq 'action') {
            $correct_envelope = 0 unless $body =~ s/\A\x01ACTION (.*)\x01\z/$1/s;
        }
        push @payload, $body;
    }
    is_deeply([join('',@payload),$input,$bounded,$correct_envelope,scalar(@payload)>1 ? 1 : 0],
        [$original,$original,1,1,1], "$kind preserves original private wire payload and chunk limits");
}
is_deeply(\@warnings, [], 'redaction and actual private sends emit no warnings');
done_testing;
