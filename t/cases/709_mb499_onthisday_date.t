# t/cases/709_mb499_onthisday_date.t
# =============================================================================
# mb499 — !onthisday [MM-DD] : viser une date précise, pas seulement aujourd'hui.
#
#   [1] _onthisday_lines accepte month/day optionnels -> SQL PARAMÉTRÉ
#       (MONTH(ts)=? AND DAY(ts)=?) au lieu de MONTH(CURDATE()) ; label daté ;
#   [2] rétrocompat : sans date, comportement identique (CURDATE, ts<CURDATE) —
#       le digest quotidien (mb496) n'est pas impacté ;
#   [3] parsing de l'argument dans mbOnThisDay_ctx (MM-DD, MM/DD ; rejet des
#       dates invalides) ;
#   [4] borne d'année correcte (une date passée cette année compte l'année en
#       cours ; une date future l'exclut).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

use Mediabot::UserCommands;
use Mediabot::Context;

sub _slurp_709 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

{
    package L709; sub new { bless {}, shift } sub log { }
    package Chan709; sub new { bless { id => $_[1] }, $_[0] } sub get_id { $_[0]->{id} }
    package STH709;
    sub new { my ($c,%a)=@_; bless { %a, i=>0, rows=>[] }, $c }
    sub execute {
        my ($s,@b)=@_; $s->{i}=0;
        push @{ $s->{cap} }, { sql => $s->{sql}, bind => [@b] };
        my $q = $s->{sql};
        if    ($q =~ /GROUP BY YEAR/) { $s->{rows} = [ {y=>2025,msgs=>10,people=>3}, {y=>2023,msgs=>4,people=>2} ] }
        elsif ($q =~ /GROUP BY nick/) { $s->{rows} = [ {nick=>'alice',c=>5} ] }
        elsif ($q =~ /CHAR_LENGTH/)   { $s->{rows} = [ {nick=>'alice',publictext=>'un message suffisamment long pour depasser vingt-cinq caracteres'} ] }
        else                          { $s->{rows} = [] }
        return 1;
    }
    sub fetchrow_hashref { my $s=shift; return undef if $s->{i}>=@{$s->{rows}}; return $s->{rows}[$s->{i}++]; }
    sub finish { 1 }
    package DBH709;
    sub new { bless { cap => $_[1] }, $_[0] }
    sub prepare { STH709->new(sql => $_[1], cap => $_[0]->{cap}) }
}

my @SENT;

return sub {
    my ($assert) = @_;

    no warnings 'redefine';
    no warnings 'once';
    local *Mediabot::UserCommands::botNotice      = sub { push @SENT, "NOTICE: $_[2]"; 1 };
    local *Mediabot::UserCommands::queueBotNotices = sub { my ($s,$n,@l)=@_; push @SENT, @l; 1 };
    local *Mediabot::UserCommands::botPrivmsg      = sub { push @SENT, $_[2]; 1 };
    local *Mediabot::UserCommands::isIrcChannelTarget = sub { defined $_[0] && $_[0] =~ /^[#&]/ };
    local *Mediabot::Helpers::chanset_enabled     = sub { 1 };

    # --- [2] rétrocompat : sans date -> CURDATE + ts < CURDATE --------------
    {
        my @cap;
        my $self = bless { dbh => DBH709->new(\@cap), logger => L709->new }, 'Mediabot';
        my @lines = Mediabot::UserCommands::_onthisday_lines($self, 42, '#teuk');
        $assert->like($lines[0], qr/On this day on #teuk \(/, 'défaut: label sans date explicite');
        $assert->like($cap[0]{sql}, qr/MONTH\(ts\) = MONTH\(CURDATE\(\)\)/, 'défaut: MONTH(CURDATE())');
        $assert->like($cap[0]{sql}, qr/ts < CURDATE\(\)/, 'défaut: borne ts < CURDATE');
        $assert->is(scalar(@{$cap[0]{bind}}), 1, 'défaut: un seul bind (id_channel)');
    }

    # --- [1] date explicite -> SQL paramétré + label daté ------------------
    {
        my @cap;
        my $self = bless { dbh => DBH709->new(\@cap), logger => L709->new }, 'Mediabot';
        my @lines = Mediabot::UserCommands::_onthisday_lines($self, 42, '#teuk', month=>12, day=>25);
        $assert->like($lines[0], qr/\(Dec 25\)/, 'date: label "(Dec 25)"');
        $assert->like($cap[0]{sql}, qr/MONTH\(ts\) = \? AND DAY\(ts\) = \?/, 'date: month/day en placeholders');
        $assert->unlike($cap[0]{sql}, qr/MONTH\(ts\) = MONTH\(CURDATE/, 'date: le filtre jour n\'utilise plus CURDATE');
        # binds : id_channel, month, day, + 3 pour la borne d'année (month, month, day)
        $assert->is(scalar(@{$cap[0]{bind}}), 6, 'date: 6 binds (id + m/d + borne année)');
        $assert->is($cap[0]{bind}[1], 12, 'date: bind month=12');
        $assert->is($cap[0]{bind}[2], 25, 'date: bind day=25');
        # la requête top-talker par année utilise aussi les placeholders m/d
        my ($tt) = grep { $_->{sql} =~ /GROUP BY nick/ } @cap;
        $assert->ok($tt && $tt->{sql} =~ /MONTH\(ts\) = \? AND DAY\(ts\) = \?/, 'date: top-talker aussi paramétré');
    }

    # --- [3] parsing dans mbOnThisDay_ctx ----------------------------------
    {
        my $run = sub {
            my ($arg) = @_;
            @SENT = ();
            my $self = bless {
                dbh => DBH709->new([]), logger => L709->new,
                channels => { '#teuk' => Chan709->new(42) },
                _otd_cooldown => {},
            }, 'Mediabot';
            my $ctx = Mediabot::Context->new(bot=>$self, nick=>'u', channel=>'#teuk',
                message=>"onthisday $arg", args=>[ split /\s+/, $arg ]);
            Mediabot::UserCommands::mbOnThisDay_ctx($ctx);
            return join("\n", @SENT);
        };

        my $ok = $run->('12-25');
        $assert->like($ok, qr/\(Dec 25\)/, 'parsing: 12-25 accepté');

        my $ok2 = $run->('01/01');
        $assert->like($ok2, qr/\(Jan 1\)/, 'parsing: 01/01 accepté (slash)');

        my $bad = $run->('13-40');
        $assert->like($bad, qr/NOTICE:.*invalid date/, 'parsing: 13-40 rejeté (mois/jour invalides)');

        my $bad2 = $run->('hello');
        $assert->like($bad2, qr/NOTICE:.*unrecognized date/, 'parsing: "hello" rejeté');
    }

    # --- [4] garde source : borne d'année conditionnelle -------------------
    {
        my $src = _slurp_709(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
        my ($fn) = $src =~ /(sub _onthisday_lines \{.*?\n\})/s; $fn //= '';
        $assert->like($fn, qr/YEAR\(ts\) < YEAR\(CURDATE\(\)\)/, '[4] borne: années passées incluses');
        $assert->like($fn, qr/\? < MONTH\(CURDATE\(\)\)/, '[4] borne: gère la date passée/future dans l\'année');
        $assert->like($fn, qr/event_type IN \('public','action'\)/, 'convention event_type (garde projet)');
    }
};
