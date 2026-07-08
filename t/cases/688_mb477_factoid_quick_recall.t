# t/cases/688_mb477_factoid_quick_recall.t
# =============================================================================
# mb477 — Rappel rapide de factoid par "?keyword".
#
# "?coffee" se comporte comme "!whatis coffee", MAIS reste SILENCIEUX si le
# factoid n'existe pas (un "?word" spontané ne doit pas spammer le canal).
# Implémenté via un sentinelle __quiet__ passé à mbWhatis_ctx.
#
# On teste le mode quiet réellement + le câblage du routage dans mediabot.pl.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

use MockBot;
use Mediabot::Context;
use Mediabot::UserCommands;

sub _slurp_688 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

{
    package FakeChan688; sub new { bless { id => $_[1] }, $_[0] } sub get_id { $_[0]->{id} }
    package FakeSTH688;
    sub new { my ($c,%a)=@_; bless { %a, i=>0 }, $c }
    sub execute {
        my ($s,@b)=@_; my $store=$s->{store}; $s->{rows}=[]; $s->{i}=0;
        if ($s->{sql} =~ /SELECT value, created_by_nick FROM FACTOID/i) {
            my ($idc,$kw)=@b; my $k="$idc\0$kw";
            $s->{rows} = exists $store->{$k} ? [ { value=>$store->{$k}{value}, created_by_nick=>$store->{$k}{nick} } ] : [];
        }
        return 1;
    }
    sub fetchrow_hashref { my $s=shift; return undef if $s->{i}>=@{$s->{rows}}; return $s->{rows}[$s->{i}++]; }
    sub finish { 1 }
    package FakeDBH688;
    sub new { bless { store => ($_[1]//{}) }, $_[0] }
    sub prepare { my ($self,$sql)=@_; FakeSTH688->new(sql=>$sql, store=>$self->{store}) }
    sub ping { 1 }
}

my @sent;
return sub {
    my ($assert) = @_;

    no warnings 'redefine';
    local *Mediabot::UserCommands::botNotice  = sub { push @sent, { to=>$_[1], text=>$_[2] } };
    local *Mediabot::UserCommands::botPrivmsg = sub { push @sent, { to=>$_[1], text=>$_[2] } };
    use warnings 'redefine';

    my %store = ( "42\0coffee" => { value => 'black gold', nick => 'alice' } );
    my $mkbot = sub {
        MockBot->new(dbh => FakeDBH688->new(\%store),
                     channels => { '#test' => FakeChan688->new(42) });
    };

    # -------------------------------------------------------------------------
    # 1. ?coffee (quiet) -> rappelle la valeur sur le canal.
    # -------------------------------------------------------------------------
    {
        @sent = ();
        my $bot = $mkbot->();
        my $ctx = Mediabot::Context->new(bot=>$bot, nick=>'bob', channel=>'#test',
            message=>'?coffee', args=>['__quiet__','coffee']);
        Mediabot::UserCommands::mbWhatis_ctx($ctx);
        my $j = join("\n", map { $_->{text} } @sent);
        $assert->like($j, qr/coffee: black gold/, '?coffee rappelle la valeur');
    }

    # -------------------------------------------------------------------------
    # 2. ?unknown (quiet) -> SILENCE total (pas de "I don't know").
    # -------------------------------------------------------------------------
    {
        @sent = ();
        my $bot = $mkbot->();
        my $ctx = Mediabot::Context->new(bot=>$bot, nick=>'bob', channel=>'#test',
            message=>'?unknown', args=>['__quiet__','unknown']);
        Mediabot::UserCommands::mbWhatis_ctx($ctx);
        $assert->is(scalar(@sent), 0, '?unknown reste silencieux (aucune sortie)');
    }

    # -------------------------------------------------------------------------
    # 3. !whatis unknown (NON quiet) -> informe (invite à learn).
    # -------------------------------------------------------------------------
    {
        @sent = ();
        my $bot = $mkbot->();
        my $ctx = Mediabot::Context->new(bot=>$bot, nick=>'bob', channel=>'#test',
            message=>'whatis unknown', args=>['unknown']);
        Mediabot::UserCommands::mbWhatis_ctx($ctx);
        my $j = join("\n", map { $_->{text} } @sent);
        $assert->like($j, qr/don't know 'unknown'/, '!whatis inconnu -> informe (non quiet)');
    }

    # -------------------------------------------------------------------------
    # 4. Câblage du routage ?keyword dans mediabot.pl
    # -------------------------------------------------------------------------
    {
        my $main = _slurp_688(File::Spec->catfile('.', 'mediabot.pl'));
        $assert->like($main, qr/\$sCommand =~ \/\^\\\?\(\[A-Za-z0-9_\.\\\-\]\{1,64\}\)\$\/ && !\@tArgs/,
            'détection ?keyword (mot collé, sans args)');
        $assert->like($main, qr/mbCommandPublic\([^)]*'whatis','__quiet__',\$keyword\)/,
            'route vers whatis avec le sentinelle __quiet__');
    }

    # -------------------------------------------------------------------------
    # 5. Doc : raccourci ?keyword mentionné.
    # -------------------------------------------------------------------------
    {
        my $med = _slurp_688(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));
        $assert->like($med, qr/Shortcut: \?keyword/, 'raccourci ?keyword documenté');
    }
};
