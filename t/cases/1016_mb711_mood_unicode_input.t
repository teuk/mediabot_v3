# t/cases/1016_mb711_mood_unicode_input.t
# =============================================================================
# mb711 — !mood accepts both representations returned by DBD::MariaDB:
# UTF-8 octets and already-decoded Perl characters. The latter used to reach
# Encode::decode unconditionally and throw "Wide character", while the public
# dispatch boundary logged the exception and returned no IRC response.
# =============================================================================

use strict;
use warnings;
use utf8;

BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

use Encode ();
use Mediabot::SocialHistory ();

{
    package Ctx1016;
    sub new     { bless { bot => $_[1], nick => $_[2], channel => $_[3] }, $_[0] }
    sub bot     { $_[0]->{bot} }
    sub nick    { $_[0]->{nick} }
    sub channel { $_[0]->{channel} }

    package Metrics1016;
    sub new { bless {}, $_[0] }
    sub inc { 1 }

    package STH1016;
    sub new { bless { sql => $_[1], row => $_[2], done => 0 }, $_[0] }
    sub execute { $_[0]->{done} = 0; 1 }
    sub fetchrow_arrayref {
        my ($self) = @_;
        if ($self->{sql} =~ /MAX\(cl\.id_channel_log\)/) {
            return if $self->{done}++;
            return [100, '2026-09-01 09:43:00', '2026-09-01'];
        }
        return if $self->{sql} !~ /SELECT cl\.publictext/ || $self->{done}++;
        return [ $self->{row} ];
    }
    sub fetchrow_hashref { return }
    sub finish { 1 }

    package DBH1016;
    sub new { bless { row => $_[1] }, $_[0] }
    sub prepare { STH1016->new($_[1], $_[0]->{row}) }
}

return sub {
    my ($assert) = @_;

    no warnings qw(redefine once);
    my @sent;
    local *Mediabot::SocialHistory::botPrivmsg = sub {
        push @sent, $_[2];
        return 1;
    };
    local *Mediabot::SocialHistory::botNotice = sub {
        push @sent, "NOTICE: $_[2]";
        return 1;
    };

    my $run = sub {
        my ($row, $label) = @_;
        @sent = ();
        my $bot = bless {
            dbh             => DBH1016->new($row),
            metrics         => Metrics1016->new,
            _mood_cooldown  => {},
            _mood_count     => {},
            achievements    => undef,
        }, 'Bot1016';
        my $ctx = Ctx1016->new($bot, 'tester', '#test');
        my $ok = eval { Mediabot::SocialHistory::mbMood_ctx($ctx); 1 };
        $assert->ok($ok, "$label: handler does not throw");
        $assert->is($@, '', "$label: no Wide character exception");
        my $all = join("\n", @sent);
        $assert->like($all, qr/Mood #test/, "$label: normal mood output");
        $assert->like($all, qr/top emoji: .*\x{D7}1/, "$label: emoji counted once");
    };

    my $chars = "café super \x{1F600}";
    $assert->ok(utf8::is_utf8($chars), 'fixture: decoded character input');
    $run->($chars, 'decoded input');

    my $octets = Encode::encode('UTF-8', $chars);
    $assert->ok(!utf8::is_utf8($octets), 'fixture: UTF-8 octet input');
    $run->($octets, 'octet input');

    open my $fh, '<:encoding(UTF-8)', 'Mediabot/SocialHistory.pm' or die $!;
    local $/;
    my $src = <$fh>;
    close $fh;
    my ($body) = $src =~ /(sub mbMood_ctx \{.*?\n\}\n)/s;
    $body //= '';
    $assert->like($body,
        qr/utf8::is_utf8\(\$txt\).*?Encode::decode\('UTF-8', \$txt, Encode::FB_DEFAULT\)/s,
        'source guard: decode only the octet representation');
};
