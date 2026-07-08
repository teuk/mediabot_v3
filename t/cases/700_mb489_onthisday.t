# t/cases/700_mb489_onthisday.t
# =============================================================================
# mb489 — !onthisday / !otd : ressort l'activité du canal au même jour
# calendaire lors des années passées (nostalgie / engagement). Basé sur
# CHANNEL_LOG, lecture seule, gated par le chanset OnThisDay.
#
# On teste le handler réel via MockBot + un faux DBH qui répond aux 3 requêtes
# (stats par année / top talker / message représentatif), + l'intégration
# (export, dispatch, alias, help, chanset, migration, garde publictext).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

use MockBot;
use Mediabot::Context;
use Mediabot::UserCommands;

sub _slurp_700 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

{
    package FakeChan700; sub new { bless { id => $_[1] }, $_[0] } sub get_id { $_[0]->{id} }

    package FakeSTH700;
    sub new { my ($c,%a)=@_; bless { %a, i=>0, rows=>[] }, $c }
    sub execute {
        my ($s,@b)=@_; my $sql=$s->{sql}; my $data=$s->{data};
        $s->{i}=0; $s->{rows}=[];
        if ($sql =~ /GROUP BY YEAR\(ts\)/) {              # stats par année
            $s->{rows} = [ @{ $data->{years} } ];
        }
        elsif ($sql =~ /GROUP BY nick ORDER BY c DESC/) { # top talker (par année)
            my $y = $b[1];
            $s->{rows} = [ { nick => ($data->{top}{$y} // '?'), c => 1 } ];
        }
        elsif ($sql =~ /ORDER BY CHAR_LENGTH\(publictext\) DESC/) { # message repr.
            $s->{rows} = [ @{ $data->{msgs} } ];
        }
        return 1;
    }
    sub fetchrow_hashref { my $s=shift; return undef if $s->{i}>=@{$s->{rows}}; return $s->{rows}[$s->{i}++]; }
    sub finish { 1 }

    package FakeDBH700;
    sub new { bless { data => $_[1] }, $_[0] }
    sub prepare { my ($self,$sql)=@_; FakeSTH700->new(sql=>$sql, data=>$self->{data}) }
    sub ping { 1 }
}

my @sent;
return sub {
    my ($assert) = @_;

    no warnings 'redefine';
    local *Mediabot::UserCommands::botNotice     = sub { push @sent, $_[2] };
    local *Mediabot::UserCommands::queueBotNotices = sub { my ($s,$n,@l)=@_; push @sent, @l; return 1; };
    use warnings 'redefine';

    my $data = {
        years => [
            { y => 2025, msgs => 42, people => 7 },
            { y => 2024, msgs => 13, people => 3 },
        ],
        top => { 2025 => 'alice', 2024 => 'bob' },
        msgs => [
            { nick => 'alice', publictext => 'this was a memorable long message from that day in 2025' },
        ],
    };
    my $mkbot = sub {
        MockBot->new(dbh => FakeDBH700->new($data),
                     channels => { '#test' => FakeChan700->new(42) });
    };

    # --- 1. cas nominal : plusieurs années -----------------------------------
    {
        @sent = ();
        my $bot = $mkbot->();
        my $ctx = Mediabot::Context->new(bot=>$bot, nick=>'carol', channel=>'#test',
            message=>'onthisday', args=>[]);
        Mediabot::UserCommands::mbOnThisDay_ctx($ctx);
        my $j = join("\n", @sent);
        $assert->like($j, qr/On this day on #test/, 'en-tête onthisday');
        $assert->like($j, qr/2024-2025/, 'span des années');
        $assert->like($j, qr/55 message\(s\)/, 'total messages (42+13)');
        $assert->like($j, qr/2025: 42 msg, 7 people, most active: alice/, 'ligne 2025 + top talker');
        $assert->like($j, qr/2024: 13 msg, 3 people, most active: bob/, 'ligne 2024 + top talker');
        $assert->like($j, qr/From 2025 — <alice> this was a memorable/, 'message représentatif');
    }

    # --- 2. rien enregistré ce jour-là ---------------------------------------
    {
        @sent = ();
        my $bot = MockBot->new(dbh => FakeDBH700->new({ years=>[], top=>{}, msgs=>[] }),
                               channels => { '#test' => FakeChan700->new(42) });
        my $ctx = Mediabot::Context->new(bot=>$bot, nick=>'carol', channel=>'#test',
            message=>'onthisday', args=>[]);
        Mediabot::UserCommands::mbOnThisDay_ctx($ctx);
        my $j = join("\n", @sent);
        $assert->like($j, qr/Nothing recorded on this channel on this day/, 'message vide gracieux');
    }

    # --- 3. refus en privé ----------------------------------------------------
    {
        @sent = ();
        my $bot = $mkbot->();
        my $ctx = Mediabot::Context->new(bot=>$bot, nick=>'carol', channel=>undef,
            message=>'onthisday', args=>[]);
        Mediabot::UserCommands::mbOnThisDay_ctx($ctx);
        my $j = join("\n", @sent);
        $assert->like($j, qr/use it in a channel/, 'refus en privé');
    }

    # --- 4. cooldown ----------------------------------------------------------
    {
        @sent = ();
        my $bot = $mkbot->();
        my $ctx = Mediabot::Context->new(bot=>$bot, nick=>'dave', channel=>'#test',
            message=>'onthisday', args=>[]);
        Mediabot::UserCommands::mbOnThisDay_ctx($ctx);   # 1er appel : ok
        my $n1 = scalar @sent;
        @sent = ();
        Mediabot::UserCommands::mbOnThisDay_ctx($ctx);   # 2e appel : cooldown
        my $j = join("\n", @sent);
        $assert->like($j, qr/please wait \d+s/, 'cooldown actif au 2e appel rapide');
    }

    # --- 5. intégration -------------------------------------------------------
    {
        my $uc = _slurp_700(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
        $assert->like($uc, qr/^\s*mbOnThisDay_ctx\s*$/m, 'mbOnThisDay_ctx exporté');
        # garde projet : pas de "publictext IS NOT NULL"
        my ($otd) = $uc =~ /(sub mbOnThisDay_ctx \{.*?\n\})/s;
        $otd //= '';
        $assert->unlike($otd, qr/publictext\s+IS\s+NOT\s+NULL/i,
            'pas de publictext IS NOT NULL (garde projet)');
        $assert->like($otd, qr/event_type IN \('public','action'\)/,
            'utilise la convention event_type');

        my $med = _slurp_700(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));
        $assert->like($med, qr/onthisday\s*=>\s*sub\s*\{\s*mbOnThisDay_ctx/, 'onthisday dans le dispatch');
        $assert->like($med, qr/otd\s*=>\s*sub\s*\{\s*mbOnThisDay_ctx/, 'alias otd dans le dispatch');
        $assert->like($med, qr/^onthisday\|onthisday\|public/m, 'onthisday documenté');
        $assert->like($med, qr/\+OnThisDay\b/, 'chanset OnThisDay documenté');

        my $sql = _slurp_700(File::Spec->catfile('.', 'install', 'mediabot.sql'));
        $assert->like($sql, qr/\(20,\s*'OnThisDay'\)/, 'chanset OnThisDay (id 20) au schéma');

        $assert->ok(-f File::Spec->catfile('.','install','migrations','20260708_onthisday_chanset.sql'),
            'migration OnThisDay présente');
        my $db = _slurp_700(File::Spec->catfile('.', 'docs', 'DB_MIGRATIONS.md'));
        $assert->like($db, qr/20260708_onthisday_chanset\.sql/, 'migration déclarée dans DB_MIGRATIONS');
    }
};
