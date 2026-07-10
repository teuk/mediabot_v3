# t/cases/708_mb498_mood_pulse.t
# =============================================================================
# mb498 — !mood enrichi d'une ligne "pulse" : QUI anime le canal (top talkers
# des 60 dernières min) et QUAND il a culminé aujourd'hui (pic horaire).
# Greffé sur le !mood existant (sentiment/énergie), sans le casser.
#
# On exécute le vrai mbMood_ctx avec un mock DBH multi-requêtes et on
# intercepte botPrivmsg pour vérifier la ligne pulse et sa forme.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

use Mediabot::UserCommands;
use Mediabot::Context;

{
    package L708; sub new { bless {}, shift } sub log { }
    package M708; sub new { bless {}, shift } sub inc { }
    package STH708;
    sub new { my ($c,%a)=@_; bless { %a, i=>0, rows=>[] }, $c }
    sub execute {
        my ($s,@b)=@_; $s->{i}=0; my $q=$s->{sql}; my $d=$s->{data};
        if    ($q =~ /GROUP BY cl\.nick/)     { $s->{rows} = $d->{talkers} }
        elsif ($q =~ /GROUP BY HOUR\(cl\.ts\)/){ $s->{rows} = $d->{peak} }
        elsif ($q =~ /SELECT cl\.publictext/) { $s->{rows} = $d->{msgs} }
        else                                  { $s->{rows} = [] }
        return 1;
    }
    sub fetchrow_arrayref { my $s=shift; return undef if $s->{i}>=@{$s->{rows}}; return $s->{rows}[$s->{i}++]; }
    sub fetchrow_hashref  { my $s=shift; return undef if $s->{i}>=@{$s->{rows}}; return $s->{rows}[$s->{i}++]; }
    sub finish { 1 }
    package DBH708;
    sub new { bless { data => $_[1] }, $_[0] }
    sub prepare { STH708->new(sql => $_[1], data => $_[0]->{data}) }
}

sub _strip { my ($s)=@_; $s =~ s/\x03\d{0,2}(?:,\d{1,2})?|\x0f|\x02//g; return $s; }

my @SENT;

return sub {
    my ($assert) = @_;

    no warnings 'redefine';
    no warnings 'once';
    local *Mediabot::UserCommands::botPrivmsg = sub { push @SENT, $_[2]; 1 };
    local *Mediabot::UserCommands::botNotice  = sub { push @SENT, "NOTICE: $_[2]"; 1 };

    my $mkctx = sub {
        my ($data) = @_;
        my $bot = bless {
            dbh          => DBH708->new($data),
            logger       => L708->new,
            metrics      => M708->new,
            channels     => {},
            _mood_count  => {},
            achievements => undef,
        }, 'Mediabot';
        return Mediabot::Context->new(bot=>$bot, nick=>'tester', channel=>'#teuk',
            message=>'mood', args=>[]);
    };

    # --- 1. cas nominal : talkers + pic ------------------------------------
    {
        @SENT = ();
        my $ctx = $mkctx->({
            msgs    => [ map { [$_] } ('lol super cool merci', 'haha genial', 'wtf nul') ],
            talkers => [ {nick=>'alice',c=>25}, {nick=>'bob',c=>12}, {nick=>'carol',c=>7} ],
            peak    => [ {h=>21,c=>88} ],
        });
        eval { Mediabot::UserCommands::mbMood_ctx($ctx) };
        my $all = join("\n", map { _strip($_) } @SENT);
        $assert->like($all, qr/Mood #teuk/, 'mood: en-tête présent');
        $assert->like($all, qr/driven by: alice \(25\), bob \(12\), carol \(7\)/,
            'pulse: top talkers listés avec compte');
        $assert->like($all, qr/peak today: 21h-22h \(88 msgs\)/,
            'pulse: pic horaire du jour');
    }

    # --- 2. pic à 23h -> wrap à 00h ----------------------------------------
    {
        @SENT = ();
        my $ctx = $mkctx->({
            msgs    => [ ['coucou'] ],
            talkers => [ {nick=>'zoe',c=>3} ],
            peak    => [ {h=>23,c=>40} ],
        });
        eval { Mediabot::UserCommands::mbMood_ctx($ctx) };
        my $all = join("\n", map { _strip($_) } @SENT);
        $assert->like($all, qr/peak today: 23h-00h \(40 msgs\)/, 'pulse: 23h wrap correctement à 00h');
    }

    # --- 3. pas de talkers -> pas de ligne pulse (best-effort, silencieux) --
    {
        @SENT = ();
        my $ctx = $mkctx->({
            msgs    => [ ['hi'] ],
            talkers => [],
            peak    => [],
        });
        eval { Mediabot::UserCommands::mbMood_ctx($ctx) };
        my $all = join("\n", map { _strip($_) } @SENT);
        $assert->unlike($all, qr/driven by:/, 'pulse: pas de "driven by" sans talkers');
        $assert->unlike($all, qr/peak today:/, 'pulse: pas de "peak" sans données');
        # mais le mood de base reste affiché
        $assert->like($all, qr/Mood #teuk/, 'mood de base toujours présent');
    }

    # --- 4. silence total : pas de pulse, message dédié --------------------
    {
        @SENT = ();
        my $ctx = $mkctx->({ msgs => [], talkers => [], peak => [] });
        eval { Mediabot::UserCommands::mbMood_ctx($ctx) };
        my $all = join("\n", map { _strip($_) } @SENT);
        $assert->like($all, qr/silence total/, 'silence: message dédié');
        $assert->unlike($all, qr/driven by:/, 'silence: pas de pulse');
    }

    # --- 5. garde source : conventions ------------------------------------
    {
        open my $fh, '<:encoding(UTF-8)',
            File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm') or die $!;
        local $/; my $src = <$fh>; close $fh;
        my ($body) = $src =~ /(sub mbMood_ctx \{.*?\n\})\n/s; $body //= '';
        $assert->like($body, qr/INTERVAL 60 MINUTE/, 'talkers: fenêtre 60 min');
        $assert->like($body, qr/cl\.ts >= CURDATE\(\)/, 'peak: sur le jour courant');
        $assert->like($body, qr/event_type IN \('public','action'\)/,
            'convention event_type (garde projet)');
        $assert->like($body, qr/eval \{ \$sth_tt->execute/, 'talkers best-effort (eval)');
        $assert->like($body, qr/eval \{ \$sth_pk->execute/, 'peak best-effort (eval)');
    }
};
